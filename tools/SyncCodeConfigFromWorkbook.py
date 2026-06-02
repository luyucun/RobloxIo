from __future__ import annotations

import json
import re
from pathlib import Path

import openpyxl


ROOT = Path(__file__).resolve().parents[1]
WORKBOOK_PATH = ROOT / "IO_BaseBalanceDraft.xlsx"
CONFIG_PATH = ROOT / "CodeConfig.lua"
SHEET_NAME = "兑换码"
HEADER_ROW = 6
DATA_START_ROW = 7
BEGIN_MARKER = "-- BEGIN GENERATED CODE ROWS"
END_MARKER = "-- END GENERATED CODE ROWS"

ONLINE_REWARD_CONFIG_PATH = ROOT / "OnlineRewardConfig.lua"
ONLINE_REWARD_SHEET_NAME = "在线奖励"
ONLINE_REWARD_HEADER_ROW = 9
ONLINE_REWARD_DATA_START_ROW = 10
ONLINE_REWARD_BEGIN_MARKER = "-- BEGIN GENERATED ONLINE REWARD ROWS"
ONLINE_REWARD_END_MARKER = "-- END GENERATED ONLINE REWARD ROWS"

SEVEN_DAY_LOGIN_REWARD_CONFIG_PATH = ROOT / "SevenDayLoginRewardConfig.lua"
SEVEN_DAY_LOGIN_REWARD_SHEET_NAME = "七日登录奖励"
SEVEN_DAY_LOGIN_REWARD_BEGIN_MARKER = "-- BEGIN GENERATED SEVEN DAY LOGIN REWARD ROWS"
SEVEN_DAY_LOGIN_REWARD_END_MARKER = "-- END GENERATED SEVEN DAY LOGIN REWARD ROWS"

SKIN_CONFIG_PATH = ROOT / "SkinConfig.lua"
SKIN_BEGIN_MARKER = "-- BEGIN GENERATED SKIN ROWS"
SKIN_END_MARKER = "-- END GENERATED SKIN ROWS"

TRAIL_CONFIG_PATH = ROOT / "TrailConfig.lua"
TRAIL_SHEET_NAME = "尾迹"
TRAIL_HEADER_ROW = 6
TRAIL_DATA_START_ROW = 7
TRAIL_BEGIN_MARKER = "-- BEGIN GENERATED TRAIL ROWS"
TRAIL_END_MARKER = "-- END GENERATED TRAIL ROWS"


def is_blank(value) -> bool:
    if value is None:
        return True
    text = str(value).strip()
    return text == "" or text.lower() in {"null", "none", "-"}


def lua_string(value) -> str:
    text = str(value)
    if "'" not in text and "\\" not in text and "\n" not in text:
        return "'" + text + "'"
    for equals_count in range(12):
        equals = "=" * equals_count
        close = f"]{equals}]"
        if close not in text:
            return f"[{equals}[{text}]{equals}]"
    raise RuntimeError("Could not encode Lua string safely.")


def lua_value(value) -> str:
    if is_blank(value):
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(int(value)) if float(value).is_integer() else repr(float(value))
    return lua_string(value)


def parse_potion_ids() -> list[int]:
    source = (ROOT / "PotionConfig.lua").read_text(encoding="utf-8")
    match = re.search(r"PotionConfig\.OrderedPotionIds\s*=\s*{(?P<body>.*?)\n}", source, re.S)
    if not match:
        return []
    return [int(value) for value in re.findall(r"\b\d+\b", match.group("body"))]


POTION_IDS = parse_potion_ids()
POTION_NAME_ALIASES = {
    "加初级药水": 1001,
    "初级药水": 1001,
    "加基础药水": 1001,
    "基础药水": 1001,
    "BasicPotion": 1001,
}


def parse_amount_token(token: str | None) -> int:
    if is_blank(token):
        return 1
    return max(1, int(float(str(token).strip())))


def parse_potion_reward(compact: str) -> dict | None:
    body = None
    for prefix in ("药水", "Potion", "potion"):
        if compact.startswith(prefix):
            body = compact[len(prefix) :]
            break
    if not body:
        return None

    explicit = re.fullmatch(r"(\d+)(?:[xX*×+](\d+))?", body)
    if explicit and explicit.group(2):
        return {
            "RewardType": "Potion",
            "PotionId": int(explicit.group(1)),
            "Amount": parse_amount_token(explicit.group(2)),
        }

    best_id = None
    best_suffix = None
    for potion_id in sorted(POTION_IDS, key=lambda value: len(str(value)), reverse=True):
        potion_id_text = str(potion_id)
        if body == potion_id_text:
            best_id = potion_id
            best_suffix = None
            break
        if body.startswith(potion_id_text):
            suffix = body[len(potion_id_text) :]
            if suffix.isdigit():
                best_id = potion_id
                best_suffix = suffix
                break

    if best_id is None and explicit:
        best_id = int(explicit.group(1))

    if best_id is None:
        return None

    return {
        "RewardType": "Potion",
        "PotionId": best_id,
        "Amount": parse_amount_token(best_suffix),
    }


def parse_reward_type_and_amount(reward_type_value, amount_value) -> tuple[dict | None, str | None]:
    if is_blank(reward_type_value):
        return None, None

    reward_type_text = str(reward_type_value).strip()
    compact = re.sub(r"\s+", "", reward_type_text).replace("＋", "+")
    amount = parse_amount_token(amount_value)

    if compact in {"经验值", "加经验", "加经验值", "Experience", "EXP", "Exp"}:
        return {"RewardType": "Experience", "Amount": amount}, None

    if compact in {"加钻石", "钻石", "Diamonds", "Diamond"}:
        return {"RewardType": "Diamonds", "Amount": amount}, None

    if compact in {"加转盘次数", "转盘次数", "转盘", "WheelSpins", "Spins"}:
        return {"RewardType": "WheelSpins", "Amount": amount}, None

    if compact in {"加护盾", "护盾", "Shield"}:
        return {"RewardType": "Shield", "Amount": amount, "DurationSeconds": amount}, None

    if compact in {"特殊皮肤", "皮肤", "Skin", "SpecialSkin"}:
        return {"RewardType": "Skin", "SkinId": amount, "Amount": 1}, None

    potion = parse_potion_reward(compact)
    if potion:
        potion["Amount"] = amount
        return potion, None

    alias_potion_id = POTION_NAME_ALIASES.get(compact)
    if alias_potion_id:
        return {"RewardType": "Potion", "PotionId": alias_potion_id, "Amount": amount}, None

    match = re.search(r"(\d+)", compact)
    if "药水" in compact or "Potion" in compact:
        if match:
            return {"RewardType": "Potion", "PotionId": int(match.group(1)), "Amount": amount}, None
        return None, f"无法解析在线奖励药水ID: {reward_type_text}"

    return None, f"无法解析在线奖励类型: {reward_type_text}"


def parse_reward_text(value) -> tuple[dict | None, str | None]:
    if is_blank(value):
        return None, None

    text = str(value).strip()
    compact = re.sub(r"\s+", "", text)
    compact = compact.replace("＋", "+")

    diamond = re.fullmatch(r"(?:加)?钻石[+]?(\d+)", compact) or re.fullmatch(r"Diamonds[+]?(\d+)", compact)
    if diamond:
        return {"RewardType": "Diamonds", "Amount": parse_amount_token(diamond.group(1))}, None

    wheel = (
        re.fullmatch(r"(?:加)?转盘次数[+]?(\d+)", compact)
        or re.fullmatch(r"转盘[+]?(\d+)", compact)
        or re.fullmatch(r"WheelSpins[+]?(\d+)", compact)
        or re.fullmatch(r"Spins[+]?(\d+)", compact)
    )
    if wheel:
        return {"RewardType": "WheelSpins", "Amount": parse_amount_token(wheel.group(1))}, None

    potion = parse_potion_reward(compact)
    if potion:
        return potion, None

    return None, f"无法解析奖励内容: {text}"


def format_reward(reward: dict) -> str:
    reward_type = reward["RewardType"]
    if reward_type == "Potion":
        return "{ RewardType = 'Potion', PotionId = %d, Amount = %d }" % (
            int(reward["PotionId"]),
            int(reward["Amount"]),
        )
    if reward_type == "WheelSpins":
        return "{ RewardType = 'WheelSpins', Amount = %d }" % int(reward["Amount"])
    if reward_type == "Diamonds":
        return "{ RewardType = 'Diamonds', Amount = %d }" % int(reward["Amount"])
    raise RuntimeError(f"Unsupported reward type: {reward_type}")


def read_code_rows():
    workbook = openpyxl.load_workbook(WORKBOOK_PATH, data_only=True)
    worksheet = workbook[SHEET_NAME]
    rows = []
    warnings = []

    for row_index in range(DATA_START_ROW, worksheet.max_row + 1):
        code_id = worksheet.cell(row_index, 3).value
        code_text = worksheet.cell(row_index, 4).value
        code_type = worksheet.cell(row_index, 5).value
        expire_at = worksheet.cell(row_index, 6).value
        max_uses = worksheet.cell(row_index, 7).value

        if all(is_blank(value) for value in (code_id, code_text, code_type, expire_at, max_uses)):
            reward_cells = [worksheet.cell(row_index, column).value for column in range(8, 11)]
            if all(is_blank(value) for value in reward_cells):
                continue

        rewards = []
        for column in range(8, 11):
            reward, warning = parse_reward_text(worksheet.cell(row_index, column).value)
            if reward:
                rewards.append(reward)
            if warning:
                warnings.append({"row": row_index, "column": column, "warning": warning})

        rows.append(
            {
                "Row": row_index,
                "CodeId": 0 if is_blank(code_id) else int(float(code_id)),
                "CodeText": "" if is_blank(code_text) else str(code_text).strip(),
                "CodeType": "Timed" if is_blank(code_type) else str(code_type).strip(),
                "ExpireAt": None if is_blank(expire_at) else expire_at,
                "MaxUses": None if is_blank(max_uses) else int(float(max_uses)),
                "Rewards": rewards,
            }
        )

    return rows, warnings


def build_generated_block(rows) -> str:
    lines = [
        BEGIN_MARKER,
        "-- Source: IO_BaseBalanceDraft.xlsx / 兑换码. Update via tools/SyncCodeConfigFromWorkbook.py.",
        "CodeConfig.ExcelRows = {",
    ]
    for row in rows:
        lines.extend(
            [
                "    {",
                f"        Row = {row['Row']},",
                f"        ['兑换码ID'] = {row['CodeId']},",
                f"        ['兑换码文本'] = {lua_value(row['CodeText'])},",
                f"        ['类型'] = {lua_value(row['CodeType'])},",
                f"        ['失效时间'] = {lua_value(row['ExpireAt'])},",
                f"        ['使用人数上限'] = {lua_value(row['MaxUses'])},",
                "        Rewards = {",
            ]
        )
        for reward in row["Rewards"]:
            lines.append(f"            {format_reward(reward)},")
        lines.extend(["        },", "    },"])
    lines.extend(["}", END_MARKER])
    return "\n".join(lines)


def build_online_reward_row(reward: dict) -> str:
    fields = [
        f"Id = {int(reward['Id'])}",
        f"RewardType = {lua_value(reward['RewardType'])}",
    ]
    if reward.get("PotionId"):
        fields.append(f"PotionId = {int(reward['PotionId'])}")
    if reward.get("SkinId"):
        fields.append(f"SkinId = {int(reward['SkinId'])}")
    if not is_blank(reward.get("Label")):
        fields.append(f"Label = {lua_value(reward['Label'])}")
    fields.append(f"Amount = {int(reward['Amount'])}")
    if reward.get("DurationSeconds"):
        fields.append(f"DurationSeconds = {int(reward['DurationSeconds'])}")
    fields.extend(
        [
            f"RequiredSeconds = {int(reward['RequiredSeconds'])}",
            f"Icon = {lua_value(reward['Icon'])}",
        ]
    )
    return "    { " + ", ".join(fields) + " },"


def build_online_reward_generated_block(rows) -> str:
    lines = [
        ONLINE_REWARD_BEGIN_MARKER,
        "-- Source: IO_BaseBalanceDraft.xlsx / 在线奖励. Update via tools/SyncCodeConfigFromWorkbook.py.",
        "OnlineRewardConfig.ExcelRows = {",
    ]
    for reward in rows:
        lines.append(build_online_reward_row(reward))
    lines.extend(["}", ONLINE_REWARD_END_MARKER])
    return "\n".join(lines)


def read_online_reward_rows():
    workbook = openpyxl.load_workbook(WORKBOOK_PATH, data_only=True)
    worksheet = workbook[ONLINE_REWARD_SHEET_NAME]
    rows = []
    warnings = []

    for row_index in range(ONLINE_REWARD_DATA_START_ROW, worksheet.max_row + 1):
        reward_id = worksheet.cell(row_index, 5).value
        reward_type = worksheet.cell(row_index, 6).value
        reward_label = worksheet.cell(row_index, 7).value
        reward_amount = worksheet.cell(row_index, 8).value
        reward_icon = worksheet.cell(row_index, 9).value
        required_seconds = worksheet.cell(row_index, 10).value

        if all(is_blank(value) for value in (reward_id, reward_type, reward_label, reward_amount, reward_icon, required_seconds)):
            continue

        reward, warning = parse_reward_type_and_amount(reward_type, reward_amount)
        if warning:
            warnings.append({"row": row_index, "column": 6, "warning": warning})
        if not reward:
            continue

        reward["Id"] = int(float(reward_id)) if not is_blank(reward_id) else len(rows) + 1
        reward["Label"] = "" if is_blank(reward_label) else str(reward_label).strip()
        reward["RequiredSeconds"] = int(float(required_seconds)) if not is_blank(required_seconds) else 0
        reward["Icon"] = "" if is_blank(reward_icon) else str(reward_icon).strip()
        rows.append(reward)

    return rows, warnings


def get_sheet(workbook, sheet_name: str, fallback_index: int):
    if sheet_name in workbook.sheetnames:
        return workbook[sheet_name]
    return workbook.worksheets[fallback_index]


def read_weapon_skin_metadata(workbook) -> dict[int, dict]:
    worksheet = get_sheet(workbook, "武器数值", 4)
    metadata = {}
    for row_index in range(5, worksheet.max_row + 1):
        skin_id = worksheet.cell(row_index, 1).value
        is_skin = worksheet.cell(row_index, 3).value
        if math_safe_int(is_skin, 0) != 1:
            continue
        resolved_skin_id = math_safe_int(skin_id, 0)
        if resolved_skin_id <= 0:
            continue
        template_name = worksheet.cell(row_index, 4).value
        skin_name = worksheet.cell(row_index, 5).value
        icon = worksheet.cell(row_index, 6).value
        template_path = worksheet.cell(row_index, 7).value
        metadata[resolved_skin_id] = {
            "Name": "" if is_blank(skin_name) else str(skin_name).strip(),
            "TemplateName": "" if is_blank(template_name) else str(template_name).strip(),
            "TemplatePath": "" if is_blank(template_path) else str(template_path).strip(),
            "IconImage": "" if is_blank(icon) else str(icon).strip(),
        }
    return metadata


def math_safe_int(value, default=0) -> int:
    if is_blank(value):
        return default
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def build_reward_label(reward: dict, workbook_metadata: dict[int, dict]) -> str:
    if not is_blank(reward.get("Label")):
        return str(reward["Label"])
    reward_type = reward.get("RewardType")
    amount = math_safe_int(reward.get("Amount"), 1)
    if reward_type == "WheelSpins":
        return f"Spin x{amount}"
    if reward_type == "Potion":
        potion_id = math_safe_int(reward.get("PotionId"), 0)
        potion_names = {
            1001: "Basic Potion",
            1002: "Advanced Potion",
            1003: "Rare Potion",
        }
        return f"{potion_names.get(potion_id, 'Potion')} x{amount}"
    if reward_type == "Skin":
        skin_id = math_safe_int(reward.get("SkinId"), 0)
        return workbook_metadata.get(skin_id, {}).get("Name") or f"Skin {skin_id}"
    if reward_type == "Diamonds":
        return f"Diamonds x{amount}"
    if reward_type == "Experience":
        return f"EXP x{amount}"
    return f"{reward_type} x{amount}"


def build_reward_icon(reward: dict, workbook_metadata: dict[int, dict]) -> str:
    if not is_blank(reward.get("Icon")):
        return str(reward["Icon"]).strip()
    reward_type = reward.get("RewardType")
    if reward_type == "WheelSpins":
        return "rbxassetid://77152368516350"
    if reward_type == "Potion":
        potion_icons = {
            1001: "rbxassetid://111415582573034",
            1002: "rbxassetid://106498508152369",
            1003: "rbxassetid://100154459165982",
        }
        return potion_icons.get(math_safe_int(reward.get("PotionId"), 0), "")
    if reward_type == "Skin":
        return workbook_metadata.get(math_safe_int(reward.get("SkinId"), 0), {}).get("IconImage") or ""
    if reward_type == "Diamonds":
        return "rbxassetid://89590364394067"
    if reward_type == "Experience":
        return "rbxassetid://112367399278116"
    return ""


def build_seven_day_reward_row(reward: dict, workbook_metadata: dict[int, dict]) -> str:
    normalized = dict(reward)
    normalized["Label"] = build_reward_label(normalized, workbook_metadata)
    normalized["Icon"] = build_reward_icon(normalized, workbook_metadata)
    fields = [
        f"DayIndex = {math_safe_int(normalized.get('DayIndex'), 1)}",
        f"RewardType = {lua_value(normalized.get('RewardType'))}",
    ]
    if normalized.get("PotionId"):
        fields.append(f"PotionId = {math_safe_int(normalized.get('PotionId'), 0)}")
    if normalized.get("SkinId"):
        fields.append(f"SkinId = {math_safe_int(normalized.get('SkinId'), 0)}")
    fields.append(f"Amount = {math_safe_int(normalized.get('Amount'), 1)}")
    fields.append(f"Label = {lua_value(normalized.get('Label'))}")
    fields.append(f"Icon = {lua_value(normalized.get('Icon'))}")
    return "    { " + ", ".join(fields) + " },"


def read_seven_day_login_reward_rows():
    workbook = openpyxl.load_workbook(WORKBOOK_PATH, data_only=True)
    worksheet = get_sheet(workbook, SEVEN_DAY_LOGIN_REWARD_SHEET_NAME, 16)
    metadata = read_weapon_skin_metadata(workbook)
    warnings = []

    def read_block(start_row: int, end_row: int) -> list[dict]:
        rows = []
        header_values = [str(worksheet.cell(start_row - 1, column).value or "").strip() for column in range(1, worksheet.max_column + 1)]
        label_column = None
        icon_column = None
        for index, header in enumerate(header_values, start=1):
            if header == "奖励名字":
                label_column = index
            elif header == "奖励图标":
                icon_column = index
        for row_index in range(start_row, end_row + 1):
            day_value = worksheet.cell(row_index, 4).value
            reward_type_value = worksheet.cell(row_index, 5).value
            amount_value = worksheet.cell(row_index, 6).value
            if all(is_blank(value) for value in (day_value, reward_type_value, amount_value)):
                continue
            reward, warning = parse_reward_type_and_amount(reward_type_value, amount_value)
            if warning:
                warnings.append({"row": row_index, "column": 5, "warning": warning})
            if not reward:
                continue
            reward["DayIndex"] = math_safe_int(day_value, len(rows) + 1)
            if label_column:
                reward["Label"] = "" if is_blank(worksheet.cell(row_index, label_column).value) else str(worksheet.cell(row_index, label_column).value).strip()
            if icon_column:
                reward["Icon"] = "" if is_blank(worksheet.cell(row_index, icon_column).value) else str(worksheet.cell(row_index, icon_column).value).strip()
            rows.append(reward)
        return rows

    first_cycle_rows = read_block(6, 12)
    repeat_cycle_rows = read_block(20, 26)
    return first_cycle_rows, repeat_cycle_rows, metadata, warnings


def build_seven_day_login_reward_generated_block(first_cycle_rows, repeat_cycle_rows, metadata) -> str:
    lines = [
        SEVEN_DAY_LOGIN_REWARD_BEGIN_MARKER,
        "-- Source: IO_BaseBalanceDraft.xlsx / 七日登录奖励. Update via tools/SyncCodeConfigFromWorkbook.py.",
        "SevenDayLoginRewardConfig.FirstCycleRewards = {",
    ]
    for reward in first_cycle_rows:
        lines.append(build_seven_day_reward_row(reward, metadata))
    lines.extend(["}", "", "SevenDayLoginRewardConfig.RepeatCycleRewards = {"])
    for reward in repeat_cycle_rows:
        lines.append(build_seven_day_reward_row(reward, metadata))
    lines.extend(["}", SEVEN_DAY_LOGIN_REWARD_END_MARKER])
    return "\n".join(lines)


def read_skin_rows():
    workbook = openpyxl.load_workbook(WORKBOOK_PATH, data_only=True)
    skin_sheet = get_sheet(workbook, "皮肤表", 12)
    metadata = read_weapon_skin_metadata(workbook)
    rows = []
    for row_index in range(5, skin_sheet.max_row + 1):
        skin_id = math_safe_int(skin_sheet.cell(row_index, 3).value, 0)
        if skin_id <= 0:
            continue
        channel = math_safe_int(skin_sheet.cell(row_index, 4).value, 0)
        if channel <= 0:
            continue
        info = metadata.get(skin_id)
        if not info:
            continue
        rows.append({
            "Id": skin_id,
            "Name": info["Name"],
            "TemplateName": info["TemplateName"],
            "TemplatePath": info["TemplatePath"],
            "IconImage": info["IconImage"],
            "PurchaseChannel": channel,
            "DiamondPrice": math_safe_int(skin_sheet.cell(row_index, 5).value, 0),
            "RobuxPrice": math_safe_int(skin_sheet.cell(row_index, 6).value, 0),
            "GamePassId": 1830742687 if skin_id == 10002 else 0,
        })
    return rows


def build_skin_generated_block(rows) -> str:
    channel_names = {
        1: "Diamonds",
        2: "GamePass",
        3: "Wheel",
        4: "SevenDayLoginReward",
    }
    lines = [
        SKIN_BEGIN_MARKER,
        "-- Source: IO_BaseBalanceDraft.xlsx / 皮肤表 + 武器数值. Update via tools/SyncCodeConfigFromWorkbook.py.",
        "SkinConfig.Skins = {",
    ]
    for row in rows:
        channel_name = channel_names.get(row["PurchaseChannel"], "Diamonds")
        lines.extend([
            "    {",
            f"        Id = {row['Id']},",
            f"        Name = {lua_value(row['Name'])},",
            f"        TemplateName = {lua_value(row['TemplateName'])},",
            f"        TemplatePath = {lua_value(row['TemplatePath'])},",
            f"        IconImage = {lua_value(row['IconImage'])},",
            f"        PurchaseChannel = SkinConfig.PurchaseChannel.{channel_name},",
            f"        DiamondPrice = {row['DiamondPrice']},",
            f"        GamePassId = {row['GamePassId']},",
            "    },",
        ])
    lines.extend(["}", SKIN_END_MARKER])
    return "\n".join(lines)


def read_trail_rows():
    workbook = openpyxl.load_workbook(WORKBOOK_PATH, data_only=True)
    worksheet = get_sheet(workbook, TRAIL_SHEET_NAME, len(workbook.worksheets) - 1)
    rows = []
    for row_index in range(TRAIL_DATA_START_ROW, worksheet.max_row + 1):
        trail_id = math_safe_int(worksheet.cell(row_index, 3).value, 0)
        if trail_id <= 0:
            continue
        trail_name = worksheet.cell(row_index, 4).value
        template_name = worksheet.cell(row_index, 5).value
        if is_blank(template_name):
            continue
        rows.append({
            "Id": trail_id,
            "Name": "" if is_blank(trail_name) else str(trail_name).strip(),
            "TemplateName": str(template_name).strip(),
            "TemplatePath": "ReplicatedStorage/Model/Trail/" + str(template_name).strip(),
            "DiamondPrice": math_safe_int(worksheet.cell(row_index, 6).value, 0),
            "RobuxPrice": math_safe_int(worksheet.cell(row_index, 7).value, 0),
            "ProductId": math_safe_int(worksheet.cell(row_index, 8).value, 0),
            "IsDefaultUnlocked": math_safe_int(worksheet.cell(row_index, 9).value, 0) == 1,
            "IconImage": "" if is_blank(worksheet.cell(row_index, 10).value) else str(worksheet.cell(row_index, 10).value).strip(),
        })
    return rows


def build_trail_generated_block(rows) -> str:
    lines = [
        TRAIL_BEGIN_MARKER,
        "-- Source: IO_BaseBalanceDraft.xlsx / 尾迹. Update via tools/SyncCodeConfigFromWorkbook.py.",
        "TrailConfig.Trails = {",
    ]
    for row in rows:
        lines.extend([
            "    {",
            f"        Id = {row['Id']},",
            f"        Name = {lua_value(row['Name'])},",
            f"        TemplateName = {lua_value(row['TemplateName'])},",
            f"        TemplatePath = {lua_value(row['TemplatePath'])},",
            f"        IconImage = {lua_value(row['IconImage'])},",
            f"        DiamondPrice = {row['DiamondPrice']},",
            f"        RobuxPrice = {row['RobuxPrice']},",
            f"        ProductId = {row['ProductId']},",
            f"        IsDefaultUnlocked = {'true' if row['IsDefaultUnlocked'] else 'false'},",
            "    },",
        ])
    lines.extend(["}", TRAIL_END_MARKER])
    return "\n".join(lines)


def replace_generated_block(source: str, generated_block: str, begin_marker: str, end_marker: str, config_path: Path) -> str:
    pattern = re.compile(re.escape(begin_marker) + r".*?" + re.escape(end_marker), re.S)
    if not pattern.search(source):
        raise RuntimeError(f"Could not find generated block markers in {config_path}")
    return pattern.sub(generated_block, source, count=1)


def main() -> None:
    rows, warnings = read_code_rows()
    source = CONFIG_PATH.read_text(encoding="utf-8")
    updated_source = replace_generated_block(source, build_generated_block(rows), BEGIN_MARKER, END_MARKER, CONFIG_PATH)
    CONFIG_PATH.write_text(updated_source, encoding="utf-8", newline="\n")

    online_rows, online_warnings = read_online_reward_rows()
    online_source = ONLINE_REWARD_CONFIG_PATH.read_text(encoding="utf-8")
    updated_online_source = replace_generated_block(
        online_source,
        build_online_reward_generated_block(online_rows),
        ONLINE_REWARD_BEGIN_MARKER,
        ONLINE_REWARD_END_MARKER,
        ONLINE_REWARD_CONFIG_PATH,
    )
    ONLINE_REWARD_CONFIG_PATH.write_text(updated_online_source, encoding="utf-8", newline="\n")

    first_cycle_rows, repeat_cycle_rows, skin_metadata, seven_day_warnings = read_seven_day_login_reward_rows()
    seven_day_source = SEVEN_DAY_LOGIN_REWARD_CONFIG_PATH.read_text(encoding="utf-8")
    updated_seven_day_source = replace_generated_block(
        seven_day_source,
        build_seven_day_login_reward_generated_block(first_cycle_rows, repeat_cycle_rows, skin_metadata),
        SEVEN_DAY_LOGIN_REWARD_BEGIN_MARKER,
        SEVEN_DAY_LOGIN_REWARD_END_MARKER,
        SEVEN_DAY_LOGIN_REWARD_CONFIG_PATH,
    )
    SEVEN_DAY_LOGIN_REWARD_CONFIG_PATH.write_text(updated_seven_day_source, encoding="utf-8", newline="\n")

    skin_rows = read_skin_rows()
    skin_source = SKIN_CONFIG_PATH.read_text(encoding="utf-8")
    updated_skin_source = replace_generated_block(
        skin_source,
        build_skin_generated_block(skin_rows),
        SKIN_BEGIN_MARKER,
        SKIN_END_MARKER,
        SKIN_CONFIG_PATH,
    )
    SKIN_CONFIG_PATH.write_text(updated_skin_source, encoding="utf-8", newline="\n")

    trail_rows = read_trail_rows()
    trail_source = TRAIL_CONFIG_PATH.read_text(encoding="utf-8")
    updated_trail_source = replace_generated_block(
        trail_source,
        build_trail_generated_block(trail_rows),
        TRAIL_BEGIN_MARKER,
        TRAIL_END_MARKER,
        TRAIL_CONFIG_PATH,
    )
    TRAIL_CONFIG_PATH.write_text(updated_trail_source, encoding="utf-8", newline="\n")
    print(json.dumps({
        "codeRows": len(rows),
        "onlineRewardRows": len(online_rows),
        "sevenDayFirstCycleRows": len(first_cycle_rows),
        "sevenDayRepeatCycleRows": len(repeat_cycle_rows),
        "skinRows": len(skin_rows),
        "trailRows": len(trail_rows),
        "warnings": warnings + online_warnings + seven_day_warnings,
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
