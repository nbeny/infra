#!/usr/bin/env python3
"""Applique un fichier .rsc sur le routeur via l'API.

RouterOS 6 n'expose ni /import ni /export a l'API. On passe donc par
/system/script : un script RouterOS accepte exactement la meme syntaxe qu'un
.rsc. Le script temporaire est ajoute, execute, puis supprime -- y compris si
l'execution echoue.

    python3 lib/ros_apply.py config/30-nat.rsc [...]
"""
import sys

from ros_api import connect_from_env, RosApiError

SCRIPT_NAME = "_ros_apply_tmp"
POLICY = "read,write,policy,test"


def _cleanup(ros):
    for row in ros.talk(["/system/script/print"]):
        if row.get("name") == SCRIPT_NAME:
            ros.talk(["/system/script/remove", "=.id=" + row[".id"]])


def apply_file(ros, path):
    with open(path, encoding="utf-8") as fh:
        source = fh.read()
    if not source.strip():
        print(f"  {path} : vide, ignore")
        return
    # Un residu d'une execution precedente ferait echouer l'ajout sur un
    # conflit de nom.
    _cleanup(ros)
    ros.talk(["/system/script/add", f"=name={SCRIPT_NAME}",
              f"=policy={POLICY}", f"=source={source}"])
    script_id = next(r[".id"] for r in ros.talk(["/system/script/print"])
                     if r.get("name") == SCRIPT_NAME)
    try:
        ros.talk(["/system/script/run", "=.id=" + script_id])
        print(f"  {path} : applique")
    finally:
        _cleanup(ros)


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: ros_apply.py <fichier.rsc> [...]")
    ros = connect_from_env()
    try:
        for path in sys.argv[1:]:
            apply_file(ros, path)
    except RosApiError as exc:
        raise SystemExit(f"ECHEC : {exc}")
    finally:
        ros.close()


if __name__ == "__main__":
    main()
