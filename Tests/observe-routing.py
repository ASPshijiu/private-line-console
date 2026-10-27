#!/usr/bin/env python3
"""Observe a disposable native app's real routing without printing credentials."""
import datetime
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

project = Path(__file__).resolve().parents[1]
base = Path.home() / "Library/Application Support/Codex Private Proxy"
config = json.loads((base / "config.yaml").read_text())
fixture = project / ".build/线路验收测试.app"
mode = sys.argv[1]
selected = mode == "selected"
target = "https://www.cloudflare.com/cdn-cgi/trace" if selected else "https://www.baidu.com"


class Controller(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(2)
        self.sock.connect(config["external-controller-unix"])


environment = {key: value for key, value in os.environ.items()
               if "proxy" not in key.lower()}
process = subprocess.Popen([str(fixture / "Contents/MacOS/Probe"), target],
                           env=environment, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True)
observed = {}
try:
    deadline = time.monotonic() + 30
    while process.poll() is None and time.monotonic() < deadline:
        connection = Controller("localhost", timeout=2)
        try:
            connection.request("GET", "/connections", headers={
                "Authorization": "Bearer " + config["secret"]})
            response = connection.getresponse()
            if response.status == 200:
                for flow in json.loads(response.read()).get("connections", []):
                    metadata = flow.get("metadata", {})
                    if metadata.get("processPath", "").startswith(str(fixture) + "/"):
                        observed[flow["id"]] = {
                            "process": metadata["processPath"],
                            "chains": flow.get("chains", []),
                            "rule": flow.get("rule", ""),
                        }
        finally:
            connection.close()
        time.sleep(0.2)
    if process.poll() is None:
        process.terminate()
    output, _ = process.communicate(timeout=5)
finally:
    if process.poll() is None:
        process.kill()
        process.wait()

payload = json.loads(output.splitlines()[0]) if output.strip() else {}
flows = list(observed.values())
passed = bool(flows) and payload.get("ok") and payload.get("http") == 200
passed = passed and all(("Codex" in flow["chains"]) == selected for flow in flows)
if selected:
    expected_exit = os.environ.get("PRIVATE_LINE_EXPECTED_EXIT_IP")
    passed = passed and bool(payload.get("ip")) and (not expected_exit or payload["ip"] == expected_exit)
result = {"time": datetime.datetime.now().astimezone().isoformat(), "mode": mode,
          "passed": bool(passed), "response": payload, "flows": flows}
destination = project / "verification"
destination.mkdir(exist_ok=True)
(destination / (mode + ".json")).write_text(json.dumps(result, ensure_ascii=False, indent=2))
print(json.dumps(result, ensure_ascii=False, indent=2))
sys.exit(0 if passed else 1)
