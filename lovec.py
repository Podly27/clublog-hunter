from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from glob import glob
import json
from pathlib import Path
import re
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

from radio import Civ, Radio, Simulator

CONFIG = Path.home() / "Library/Application Support/DX Lovec/config.json"
BANDS = (160, 80, 60, 40, 30, 20, 17, 15, 12, 10, 6, 4)
DEFAULT_PORT = "/dev/cu.usbmodem12103"


def callsign(value):
    value = value.strip().upper()
    if not re.fullmatch(r"[A-Z0-9]+(?:/[A-Z0-9]+)*", value) or not any(c.isdigit() for c in value):
        raise ValueError("Enter a valid amateur radio callsign.")
    return value


def parse_mhz(value):
    try:
        hz = Decimal(value.replace(",", ".")) * 1_000_000
        if hz.is_finite() and 30_000 <= hz <= 74_800_000 and hz == int(hz):
            return int(hz)
    except InvalidOperation:
        pass
    raise ValueError("Enter a frequency in MHz, for example 14.074.")


NUMBER = r"\d+(?:[.,]\d+)?"
FREQUENCY_WITH_SPLIT = re.compile(rf"\s*({NUMBER})(?:\s*([+-])\s*({NUMBER})\s*(?:kHz)?)?\s*", re.I)


def parse_frequency(value):
    match = FREQUENCY_WITH_SPLIT.fullmatch(value)
    if not match:
        raise ValueError("Enter MHz, with an optional split in kHz: 14.055 +5.")
    base, sign, offset = match.groups()
    rx = parse_mhz(base)
    if not offset:
        return rx, None
    delta = Decimal(sign + offset.replace(",", ".")) * 1000
    tx = rx + delta
    if not 30_000 <= tx <= 74_800_000 or tx != int(tx) or not delta:
        raise ValueError("Enter a nonzero split in kHz with up to three decimal places.")
    return rx, int(tx)


def cluster_tx(comment, rx):
    # Match explicit offsets or an absolute listening frequency. Skip ranges and bare UP.
    if re.search(r"(?<!\w)(?:UP|DN|DOWN)(?![A-Z])\s*\d+([.,]\d+)?\s*(?:[-–—/]|TO\b)\s*\d", comment, re.I):
        return None
    hints = set()
    for match in re.finditer(rf"(?<![\w.,+-])(?:(UP|DN|DOWN)\s*|([+-])\s*)({NUMBER})(?![\w.,])", comment, re.I):
        word, sign, number = match.groups()
        # A standalone signed number can be a signal report. Require kHz in that notation.
        if sign and not re.match(r"\s*kHz\b", comment[match.end():], re.I):
            continue
        value = Decimal(number.replace(",", "."))
        if 0 < value <= 100:
            hints.add(rx + value * (1000 if (word or sign).upper() in ("UP", "+") else -1000))
    for match in re.finditer(rf"\b(?:QSX|LISTENING(?:\s+ON)?)\s+({NUMBER})(?![\w.,])", comment, re.I):
        value = Decimal(match[1].replace(",", "."))
        tx = value * (1000 if value >= 1000 else 1_000_000)
        if 0 < abs(tx - rx) <= 100_000:
            hints.add(tx)
    if len(hints) == 1:
        tx = hints.pop()
        if 30_000 <= tx <= 74_800_000 and tx == int(tx):
            return int(tx)
    return None


def cluster_splits(target):
    query = urlencode({"calls": target, "modes": "CW,SSB", "limit": 100})
    request = Request("https://www.hamqth.com/api/v2/spots?" + query, headers={"Accept": "application/json"})
    with urlopen(request, timeout=5) as response:
        payload = json.load(response, parse_float=Decimal)
    now = datetime.now(timezone.utc)
    result = []
    for spot in payload["spots"]:
        try:
            if spot["dxcall"].upper() != target:
                continue
            when = datetime.fromisoformat(spot["time"].replace("Z", "+00:00"))
            mode = {"CW": "C", "SSB": "P", "USB": "P", "LSB": "P"}.get(spot.get("mode"))
            band = int(spot["band"].removesuffix("M"))
            rx = parse_mhz(str(Decimal(str(spot["freq"])) / 1000))
            if not mode or band not in BANDS or not now - timedelta(minutes=10) <= when <= now + timedelta(minutes=1):
                continue
            tx = cluster_tx(spot.get("comment") or "", rx)
        except (KeyError, TypeError, ValueError, InvalidOperation):
            continue
        row = {"slot": f"{band}:{mode}", "rx": rx, "expires": (when + timedelta(minutes=10)).timestamp()}
        if tx is not None:
            row["tx"] = tx
        result.append((when, row))
    return [row for _, row in sorted(result, key=lambda item: item[0], reverse=True)]


def club_expeditions(token):
    request = Request(
        "https://clublog.org/api/v1/expeditions?v=2",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    with urlopen(request, timeout=12) as response:
        payload = json.load(response)
    rows = payload.get("expeditions", payload.get("data")) if isinstance(payload, dict) else payload
    if not isinstance(rows, list):
        raise ValueError("Club Log returned an unexpected expedition list.")
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=7)
    result = set()
    parsed = 0
    for row in rows:
        if isinstance(row, dict):
            name = row.get("callsign") or row.get("call")
            last_qso = row.get("last_qso") or row.get("lastQso") or row.get("last") or row.get("last_qso_date")
        elif isinstance(row, list) and len(row) >= 3:
            name, last_qso = row[0], row[-2]
        else:
            continue
        if not isinstance(name, str) or not isinstance(last_qso, (str, int, float)):
            continue
        try:
            call = callsign(name)
            if isinstance(last_qso, str):
                stamp = datetime.fromisoformat(last_qso.strip().replace("Z", "+00:00"))
                if stamp.tzinfo is None:
                    stamp = stamp.replace(tzinfo=timezone.utc)
            else:
                stamp = datetime.fromtimestamp(last_qso, tz=timezone.utc)
        except (ValueError, OverflowError, OSError):
            continue
        parsed += 1
        if cutoff <= stamp <= now:
            result.add(call)
    if rows and not parsed:
        raise ValueError("Club Log returned no readable last-QSO dates.")
    return sorted(result)


def worked_slots(operator, expedition, api_key):
    operator, expedition = callsign(operator), callsign(expedition)
    if api_key.startswith("cl_"):
        path = quote(expedition, safe="")
        query = urlencode({"call": operator})
        request = Request(
            f"https://clublog.org/api/v1/logs/{path}/search?{query}",
            headers={"Authorization": f"Bearer {api_key}", "Accept": "application/json"},
        )
    else:
        query = urlencode({"call": operator, "log": expedition, "api": api_key})
        request = f"https://clublog.org/logsearchjson.php?{query}"
    with urlopen(request, timeout=12) as response:
        result = json.load(response)
    if api_key.startswith("cl_"):
        result = result.get("slots") if isinstance(result, dict) else None
    if not isinstance(result, (dict, list)) or isinstance(result, list) and result:
        raise ValueError("Club Log returned unexpected data.")
    return {(int(band), mode) for band, counts in dict(result).items()
            if band.isdecimal() and isinstance(counts, dict)
            for mode, count in counts.items() if isinstance(count, int) and count > 0}

from urllib.error import HTTPError
import sys


def club_log_error(error, key):
    prefix = f"Club Log HTTP {error.code}."
    with error:
        body = error.read(8192)
    try:
        payload = json.loads(body)
    except (ValueError, UnicodeError):
        payload = None
    if isinstance(payload, dict):
        detail = payload.get("message") or payload.get("detail") or payload.get("error")
        if isinstance(detail, dict):
            detail = detail.get("message") or detail.get("code")
        if isinstance(detail, str):
            detail = re.sub(r"cl_[A-Za-z0-9_-]+", "[token]", detail.replace(key, "[token]"))
            detail = " ".join(detail.split())[:160]
            if detail:
                return f"{prefix} {detail}"
    if error.code == 403 and key.startswith("cl_"):
        if not isinstance(payload, dict):
            return f"{prefix} The server returned a non-JSON error. Check clublog.org/check.php."
        return f"{prefix} Verify that My callsign belongs to the same Club Log account."
    if error.code == 401:
        return f"{prefix} Check that you pasted the entire token."
    return prefix


class Controller:
    radio = None

    def __init__(self):
        self.rejected_keys = set()

    def run(self, action, data):
        if action == "setup":
            try:
                config = json.loads(CONFIG.read_text())
            except FileNotFoundError:
                config = {}
            return {"config": config, "ports": sorted(p for p in glob("/dev/cu.*") if "usb" in p)}
        if action == "save":
            config = {field: data[field] for field in ("operator", "targets", "port", "baud", "address")}
            config["frequencies"] = data.get("frequencies", {})
            CONFIG.parent.mkdir(parents=True, exist_ok=True)
            temp = CONFIG.with_suffix(".tmp")
            temp.write_text(json.dumps(config))
            temp.replace(CONFIG)
            return "Settings saved."
        if action in ("lookup", "expeditions"):
            key = data["key"].strip()
            if not key:
                raise ValueError("Enter a Club Log REST API token (cl_…) in Settings.")
            if key in self.rejected_keys:
                raise ValueError("Club Log already rejected this token. Check the token type and access at clublog.org/check.php.")
            try:
                if action == "expeditions":
                    return club_expeditions(key)
                return sorted(worked_slots(data["operator"], data["target"], key))
            except HTTPError as exc:
                if exc.code in (401, 403):
                    self.rejected_keys.add(key)
                raise ValueError(club_log_error(exc, key)) from None
        if action == "cluster_splits":
            return cluster_splits(callsign(data["target"]))
        if action == "validate_frequency":
            parse_frequency(data["frequency"])
            return "Frequency validated."
        if action == "radio_status":
            if self.radio is None:
                return {"connected": False}
            try:
                hz = self.radio.frequency()
            except (OSError, ValueError):
                self.close()
                return {"connected": False}
            try:
                mode = self.radio.mode_group()
            except (OSError, ValueError):
                mode = None
            return {"connected": True, "frequencyHz": hz, "mode": mode}
        if action == "disconnect":
            self.close()
            return "Radio disconnected."
        if action == "connect":
            if self.radio is not None:
                raise ValueError("Disconnect the current connection first.")
            if data.get("simulate"):
                self.radio = Simulator()
                return "Simulation active."
            path = data["port"]
            if path == "/dev/cu.usbmodem12101" or path == "/dev/tty.usbmodem12101":
                raise ValueError("This port is reserved for WSJT-X. Select the second port.")
            if path not in glob("/dev/cu.usb*"):
                raise ValueError("Select a connected USB port beginning with /dev/cu.usb.")
            address, baud = int(data["address"], 16), int(data["baud"])
            if not 1 <= address <= 0xDF:
                raise ValueError("Invalid CI-V address.")
            radio = Radio(Civ(path, baud, address))
            try:
                hz = radio.frequency()
            except Exception:
                radio.close()
                raise
            self.radio = radio
            return f"Connected · {hz / 1e6:.6f} MHz"
        if self.radio is None:
            raise ValueError("Connect the radio or start simulation in Settings.")
        if action == "vfo":
            return f"{self.radio.frequency() / 1e6:.6f}"
        if action == "tune":
            hz, tx = parse_frequency(data["frequency"])
            mode = data["mode"]
            if mode == "PHONE":
                mode = "LSB" if hz < 10_000_000 else "USB"
            if mode not in ("FT8", "CW", "USB", "LSB"):
                raise ValueError("Unknown operating mode.")
            if mode == "FT8":
                tx = None
            self.radio.tune(hz, mode, tx)
            split_status = f"TX {tx / 1e6:.6f} MHz" if tx is not None else "Split off"
            return f"{hz / 1e6:.6f} MHz · {mode} · {split_status}"
        if action == "stop_cw":
            self.radio.stop_cw()
            return "CW stop command acknowledged."
        if action == "send_cw":
            self.radio.send_cw(data["value"])
            return "CW transmit command acknowledged."
        raise ValueError("Unknown operation.")

    def close(self):
        if self.radio is not None:
            self.radio.close()
            self.radio = None


def main():
    controller = Controller()
    try:
        for line in sys.stdin:
            try:
                request = json.loads(line)
                response = {"result": controller.run(request["action"], request.get("data", {}))}
            except (OSError, ValueError, AttributeError, KeyError, TypeError) as exc:
                response = {"error": str(exc)}
            print(json.dumps(response), flush=True)
    finally:
        controller.close()


if __name__ == "__main__":
    main()
