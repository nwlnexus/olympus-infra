"""Print one line per task result from ansible's json stdout callback: <status>\t<task name>."""
import json
import sys

doc = json.load(sys.stdin)
for play in doc["plays"]:
    for task in play["tasks"]:
        for res in task["hosts"].values():
            if res.get("failed"):
                status = "failed"
            elif res.get("skipped"):
                status = "skipped"
            elif res.get("changed"):
                status = "changed"
            else:
                status = "ok"
            print(f"{status}\t{task['task']['name']}")
s = doc["stats"]
for host, st in s.items():
    print(f"# stats {host}: " + " ".join(f"{k}={st[k]}" for k in ("ok", "changed", "skipped", "failures")), file=sys.stderr)
