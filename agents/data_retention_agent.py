#!/usr/bin/env python3
import json
import logging
import os
import sys
from datetime import datetime, timezone
import requests

CONFIG_PATH = os.getenv("RETENTION_CONFIG_PATH", "/opt/automation/config.json")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("DataRetentionAgent")


def load_configuration(path: str) -> dict:
    if not os.path.isfile(path):
        logger.critical(f"Файл конфигурации не найден по пути: {path}")
        sys.exit(1)
    try:
        with open(path, "r", encoding="utf-8") as file_descriptor:
            return json.load(file_descriptor)
    except Exception as error:
        logger.critical(f"Ошибка синтаксического анализа конфигурации: {error}")
        sys.exit(1)


def api_request(url: str, headers: dict, params: dict = None) -> dict:
    try:
        response = requests.get(url, headers=headers, params=params, timeout=15)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as error:
        logger.error(f"Сетевой сбой при обращении к {url}: {error}")
        return None


def execute_retention_policy():
    config = load_configuration(CONFIG_PATH)
    logger.info("Инициализация цикла проверки политик хранения данных.")

    dry_run = config["settings"].get("dry_run", True)
    retention_days = config["settings"].get("retention_days", 30)
    exclude_tag = config["settings"].get("exclude_tag", "collection")
    ignored_users = set(config["settings"].get("ignore_users", []))

    if dry_run:
        logger.warning("Активирован демонстрационный режим. Удаление файлов отключено.")

    jellyfin_url = config["jellyfin"]["url"].rstrip("/")
    jellyfin_headers = {"X-Emby-Token": config["jellyfin"]["api_key"]}

    users_payload = api_request(f"{jellyfin_url}/Users", headers=jellyfin_headers)
    if users_payload is None:
        logger.error("Прерывание: невозможно верифицировать список пользователей Jellyfin.")
        return

    active_users = [
        user for user in users_payload
        if user.get("Name") not in ignored_users
    ]

    if not active_users:
        logger.error("Прерывание: отсутствуют активные пользователи для проверки условий.")
        return

    logger.info(f"Контрольная группа пользователей: {[u['Name'] for u in active_users]}")

    radarr_url = config["radarr"]["url"].rstrip("/")
    radarr_headers = {"X-Api-Key": config["radarr"]["api_key"]}

    movies_list = api_request(f"{radarr_url}/api/v3/movie", headers=radarr_headers)
    if movies_list is None:
        logger.error("Прерывание: невозможно получить список медиатеки из Radarr.")
        return

    tags_list = api_request(f"{radarr_url}/api/v3/tag", headers=radarr_headers) or []
    protected_tag_id = next(
        (tag["id"] for tag in tags_list if tag.get("label") == exclude_tag),
        None
    )

    now_utc = datetime.now(timezone.utc)

    for movie in movies_list:
        title = movie.get("title", "Неизвестный заголовок")
        movie_id = movie.get("id")

        if not movie.get("hasFile", False):
            continue

        if protected_tag_id and protected_tag_id in movie.get("tags", []):
            logger.info(f"Пропуск объекта '{title}': присвоен защитный тег '{exclude_tag}'.")
            continue

        tmdb_id = movie.get("tmdbId")
        if not tmdb_id:
            logger.warning(f"Пропуск объекта '{title}': отсутствует идентификатор TMDB.")
            continue

        search_query = {
            "Recursive": "true",
            "AnyProviderIdEquals": f"tmdb.{tmdb_id}",
            "IncludeItemTypes": "Movie",
            "Fields": "ProviderIds"
        }

        jellyfin_search = api_request(
            f"{jellyfin_url}/Items",
            headers=jellyfin_headers,
            params=search_query
        )

        if not jellyfin_search or not jellyfin_search.get("Items"):
            logger.warning(f"Пропуск объекта '{title}': не сопоставлен в каталоге Jellyfin.")
            continue

        matched_item = None
        for item in jellyfin_search["Items"]:
            registered_tmdb = item.get("ProviderIds", {}).get("Tmdb")
            if str(registered_tmdb) == str(tmdb_id):
                matched_item = item
                break

        if not matched_item:
            logger.warning(f"Конфликт метаданных: найденный объект не соответствует TMDB {tmdb_id}.")
            continue

        target_item_id = matched_item["Id"]
        retain_reasons = []

        for user in active_users:
            user_item_data = api_request(
                f"{jellyfin_url}/Users/{user['Id']}/Items/{target_item_id}",
                headers=jellyfin_headers
            )

            if user_item_data is None:
                retain_reasons.append(f"ошибка опроса профиля {user['Name']}")
                break

            user_meta = user_item_data.get("UserData", {})

            if user_meta.get("IsFavorite", False):
                retain_reasons.append(f"в избранном у пользователя {user['Name']}")
                break

            if not user_meta.get("Played", False):
                retain_reasons.append(f"не просмотрено пользователем {user['Name']}")
                break

            last_played_raw = user_meta.get("LastPlayedDate")
            if last_played_raw:
                try:
                    cleaned_date = last_played_raw.split(".")[0].rstrip("Z")
                    played_time = datetime.fromisoformat(cleaned_date).replace(tzinfo=timezone.utc)
                    age_days = (now_utc - played_time).days
                    if age_days < retention_days:
                        retain_reasons.append(f"минимальный срок не истек для {user['Name']} ({age_days} из {retention_days} дн.)")
                        break
                except ValueError:
                    pass

        if retain_reasons:
            logger.info(f"Сохранение объекта '{title}': {'; '.join(retain_reasons)}.")
        else:
            logger.info(f"Удаление объекта '{title}': критерии истечения срока соблюдены.")
            if not dry_run:
                delete_url = f"{radarr_url}/api/v3/movie/{movie_id}"
                delete_params = {"deleteFiles": "true", "addImportExclusion": "false"}
                try:
                    deletion_response = requests.delete(
                        delete_url,
                        headers=radarr_headers,
                        params=delete_params,
                        timeout=15
                    )
                    deletion_response.raise_for_status()
                    logger.info(f"Объект '{title}' успешно удален из хранилища.")
                except requests.exceptions.RequestException as error:
                    logger.error(f"Сбой при удалении объекта '{title}': {error}")

    logger.info("Цикл аудита политик хранения завершен.")


if __name__ == "__main__":
    execute_retention_policy()
