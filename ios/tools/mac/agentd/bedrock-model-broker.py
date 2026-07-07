#!/usr/bin/env python3
import argparse
import http.server
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


DEFAULT_MODEL = "anthropic.claude-haiku-4-5-20251001-v1:0"


def env_first(*names, default=""):
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return default


def env_int(name, default):
    value = os.environ.get(name) or str(default)
    return int(value)


def env_float(name, default):
    value = os.environ.get(name) or str(default)
    return float(value)


def json_response(handler, status, payload):
    encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(encoded)))
    handler.end_headers()
    handler.wfile.write(encoded)


def compact_json(value, limit=12000):
    text = json.dumps(value, separators=(",", ":"), sort_keys=True)
    if len(text) > limit:
        return text[:limit] + "...<truncated>"
    return text


def bedrock_converse(token, region, model, request_body, timeout, runtime_url):
    endpoint = runtime_url.rstrip("/") if runtime_url else f"https://bedrock-runtime.{region}.amazonaws.com"
    model_path = urllib.parse.quote(model, safe="")
    url = f"{endpoint}/model/{model_path}/converse"
    goal = request_body.get("goal") or ""
    context = request_body.get("context") if isinstance(request_body.get("context"), dict) else {}
    tools = request_body.get("tools") if isinstance(request_body.get("tools"), list) else []
    instructions = request_body.get("instructions") or "Return exactly one JSON object."
    prompt = (
        "You are the model decision broker for OpenPhone-iOS. The iPhone daemon is the "
        "runtime authority and will execute only a registered tool from your decision.\n\n"
        f"Goal:\n{goal}\n\n"
        f"Registered tools:\n{json.dumps(tools, separators=(',', ':'))}\n\n"
        f"Context JSON:\n{compact_json(context)}\n\n"
        "Return exactly one JSON object with this schema and no prose outside the JSON:\n"
        '{"schema":"openphone.model_decision.v1","thought":"short rationale",'
        '"tool":"finish_task","arguments":{"summary":"short result"},'
        '"expected_visible_change":"none","confidence":0.0}\n\n'
        "For this provider-backed validation request, choose finish_task unless the context "
        "explicitly proves the task should fail. Do not request UI-driving tools."
    )
    body = {
        "system": [{"text": instructions}],
        "messages": [{"role": "user", "content": [{"text": prompt}]}],
        "inferenceConfig": {
            "maxTokens": env_int("OPENPHONE_BEDROCK_MAX_TOKENS", 800),
            "temperature": env_float("OPENPHONE_BEDROCK_TEMPERATURE", 0),
        },
    }
    encoded = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=encoded,
        method="POST",
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
    )
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            response_body = response.read()
            status = response.status
    except urllib.error.HTTPError as exc:
        detail = exc.read(2048).decode("utf-8", errors="replace")
        return {
            "ok": False,
            "http_status": exc.code,
            "reason": "bedrock_http_error",
            "detail": detail[:500],
            "latency_ms": int((time.time() - started) * 1000),
        }
    except Exception as exc:
        return {
            "ok": False,
            "http_status": 0,
            "reason": "bedrock_request_failed",
            "detail": str(exc)[:500],
            "latency_ms": int((time.time() - started) * 1000),
        }
    try:
        parsed = json.loads(response_body.decode("utf-8"))
    except Exception as exc:
        return {
            "ok": False,
            "http_status": status,
            "reason": "bedrock_response_not_json",
            "detail": str(exc)[:500],
            "latency_ms": int((time.time() - started) * 1000),
        }
    blocks = (((parsed.get("output") or {}).get("message") or {}).get("content") or [])
    text_parts = [block.get("text") for block in blocks if isinstance(block, dict) and isinstance(block.get("text"), str)]
    decision_text = "\n".join(text_parts).strip()
    if not decision_text:
        return {
            "ok": False,
            "http_status": status,
            "reason": "bedrock_empty_text",
            "latency_ms": int((time.time() - started) * 1000),
        }
    return {
        "ok": True,
        "http_status": status,
        "decision_json": decision_text,
        "usage": parsed.get("usage") if isinstance(parsed.get("usage"), dict) else {},
        "latency_ms": int((time.time() - started) * 1000),
    }


def main():
    parser = argparse.ArgumentParser(description="OpenPhone provider-backed Bedrock model broker")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()

    token = env_first("AWS_BEARER_TOKEN_BEDROCK", "OPENPHONE_BEDROCK_BEARER_TOKEN")
    region = env_first("OPENPHONE_BEDROCK_REGION", "AWS_REGION", "AWS_DEFAULT_REGION", default="us-east-1")
    model = env_first("OPENPHONE_BEDROCK_MODEL", default=DEFAULT_MODEL)
    timeout = env_float("OPENPHONE_BEDROCK_TIMEOUT_SECONDS", 60)
    runtime_url = env_first("OPENPHONE_BEDROCK_RUNTIME_URL")
    if not token:
        print("missing AWS_BEARER_TOKEN_BEDROCK or OPENPHONE_BEDROCK_BEARER_TOKEN", file=sys.stderr)
        return 2

    class Handler(http.server.BaseHTTPRequestHandler):
        counter = 0

        def log_message(self, fmt, *items):
            return

        def do_POST(self):
            if self.path != "/decision":
                json_response(self, 404, {"status": "error", "reason": "not_found"})
                return
            length = int(self.headers.get("Content-Length", "0") or "0")
            body = self.rfile.read(length)
            try:
                request_body = json.loads(body.decode("utf-8"))
            except Exception:
                json_response(self, 400, {"status": "error", "reason": "request_not_json"})
                return
            Handler.counter += 1
            result = bedrock_converse(token, region, model, request_body, timeout, runtime_url)
            log_record = {
                "event": "provider_broker_request",
                "request_count": Handler.counter,
                "ok": result.get("ok"),
                "http_status": result.get("http_status"),
                "reason": result.get("reason", ""),
                "latency_ms": result.get("latency_ms"),
                "model": model,
            }
            print(json.dumps(log_record, separators=(",", ":")), flush=True)
            if not result.get("ok"):
                json_response(self, 502, {
                    "status": "error",
                    "reason": result.get("reason", "provider_error"),
                    "http_status": result.get("http_status", 0),
                    "metadata": {
                        "provider": "bedrock_converse",
                        "model": model,
                        "latency_ms": result.get("latency_ms", 0),
                    },
                })
                return
            json_response(self, 200, {
                "schema": "openphone.model_response.v1",
                "decision_json": result["decision_json"],
                "metadata": {
                    "provider": "bedrock_converse",
                    "provider_backed": True,
                    "model": model,
                    "region": region,
                    "request_count": Handler.counter,
                    "latency_ms": result.get("latency_ms", 0),
                },
                "usage": result.get("usage", {}),
            })

    server = http.server.ThreadingHTTPServer((args.host, args.port), Handler)
    port_file = pathlib.Path(args.port_file)
    port_file.write_text(str(server.server_port), encoding="utf-8")
    print(json.dumps({
        "event": "provider_broker_started",
        "host": args.host,
        "port": server.server_port,
        "provider": "bedrock_converse",
        "model": model,
        "region": region,
    }, separators=(",", ":")), flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
