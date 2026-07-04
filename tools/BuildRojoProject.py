import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECT_PATH = ROOT / "default.project.json"

SCRIPT_TYPE_BY_CLASS = {
    "Script": "Script",
    "LocalScript": "LocalScript",
    "ModuleScript": "ModuleScript",
}

PATH_RE = re.compile(r"(?:Studio放置路径|Studio path):\s*([^\r\n]+)")
TYPE_RE = re.compile(r"(?:脚本类型|Type):\s*([^\r\n]+)")


def read_script_metadata(path: Path):
    text = path.read_text(encoding="utf-8-sig", errors="replace")[:1200]
    type_match = TYPE_RE.search(text)
    path_match = PATH_RE.search(text)
    if not type_match or not path_match:
        return None

    script_type = type_match.group(1).strip()
    studio_path = path_match.group(1).strip().replace("\\", "/")
    return script_type, studio_path


def ensure_child(node: dict, name: str, class_name: str | None = None) -> dict:
    child = node.get(name)
    if child is None:
        child = {}
        node[name] = child
    if class_name and "$className" not in child:
        child["$className"] = class_name
    return child


def insert_script(root: dict, studio_path: str, script_type: str, local_path: Path):
    parts = [part for part in studio_path.split("/") if part]
    if len(parts) < 2 or parts[0] == "game":
        raise ValueError(f"Unsupported Studio path: {studio_path}")
    if script_type not in SCRIPT_TYPE_BY_CLASS:
        raise ValueError(f"Unsupported script type {script_type!r} for {local_path.name}")

    node = root
    for part in parts[:-1]:
        node = ensure_child(node, part, "Folder")

    leaf_name = parts[-1]
    if leaf_name in node:
        raise ValueError(f"Duplicate Studio path generated: {studio_path}")

    node[leaf_name] = {
        "$path": local_path.name,
    }


def mark_ignore_unknown(node: dict, path: tuple[str, ...]):
    current = node
    for part in path:
        current = current.get(part)
        if current is None:
            return
    current["$ignoreUnknownInstances"] = True


def sort_tree(value):
    if not isinstance(value, dict):
        return value

    special = {}
    normal = {}
    for key, item in value.items():
        if key.startswith("$"):
            special[key] = sort_tree(item)
        else:
            normal[key] = sort_tree(item)

    return {
        **{key: special[key] for key in sorted(special)},
        **{key: normal[key] for key in sorted(normal)},
    }


def build_project():
    tree = {
        "$className": "DataModel",
        "ReplicatedStorage": {
            "$className": "ReplicatedStorage",
            "$ignoreUnknownInstances": True,
            "Shared": {
                "$className": "Folder",
                "$ignoreUnknownInstances": True,
            },
        },
        "ServerScriptService": {
            "$className": "ServerScriptService",
            "$ignoreUnknownInstances": True,
            "Services": {
                "$className": "Folder",
                "$ignoreUnknownInstances": True,
            },
        },
        "StarterPlayer": {
            "$className": "StarterPlayer",
            "$ignoreUnknownInstances": True,
            "StarterPlayerScripts": {
                "$className": "StarterPlayerScripts",
                "$ignoreUnknownInstances": True,
                "Controllers": {
                    "$className": "Folder",
                    "$ignoreUnknownInstances": True,
                },
            },
        },
    }

    mapped = []
    skipped = []
    for script_path in sorted(ROOT.glob("*.lua")):
        metadata = read_script_metadata(script_path)
        if metadata is None:
            skipped.append(script_path.name)
            continue

        script_type, studio_path = metadata
        insert_script(tree, studio_path, script_type, script_path)
        mapped.append(
            {
                "file": script_path.name,
                "type": script_type,
                "studioPath": studio_path,
            }
        )

    for path in [
        ("ReplicatedStorage",),
        ("ReplicatedStorage", "Shared"),
        ("ServerScriptService",),
        ("ServerScriptService", "Services"),
        ("StarterPlayer",),
        ("StarterPlayer", "StarterPlayerScripts"),
        ("StarterPlayer", "StarterPlayerScripts", "Controllers"),
    ]:
        mark_ignore_unknown(tree, path)

    project = {
        "name": "RobloxIo",
        "servePort": 34872,
        "servePlaceIds": [73988417166286],
        "tree": sort_tree(tree),
    }

    return project, mapped, skipped


def main():
    project, mapped, skipped = build_project()
    PROJECT_PATH.write_text(
        json.dumps(project, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(
        json.dumps(
            {
                "projectPath": str(PROJECT_PATH),
                "mappedScripts": len(mapped),
                "skippedFiles": skipped,
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
