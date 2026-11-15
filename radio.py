"""Serial CI-V transport and IC-7300MK2 operations."""
import os
import select
import termios
import time


class Civ:
    def __init__(self, path, baud, address):
        self.address = address
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        self.buffer = b""
        try:
            attrs = termios.tcgetattr(self.fd)
            speed = getattr(termios, f"B{baud}")
            attrs[:6] = [0, 0, termios.CS8 | termios.CREAD | termios.CLOCAL, 0, speed, speed]
            attrs[6][termios.VMIN] = 1
            attrs[6][termios.VTIME] = 0
            termios.tcsetattr(self.fd, termios.TCSANOW, attrs)
            termios.tcflush(self.fd, termios.TCIFLUSH)
        except Exception:
            self.close()
            raise

    def close(self):
        os.close(self.fd)

    def command(self, data, response=None):
        header = bytes((0xFE, 0xFE, self.address, 0xE0))
        incoming = bytes((0xFE, 0xFE, 0xE0, self.address))
        deadline = time.monotonic() + 1.2
        packet = header + data + b"\xfd"
        while packet:
            if not select.select([], [self.fd], [], max(0, deadline - time.monotonic()))[1]:
                raise TimeoutError("The serial port is not accepting data.")
            packet = packet[os.write(self.fd, packet):]
        while time.monotonic() < deadline:
            if b"\xfd" not in self.buffer:
                if not select.select([self.fd], [], [], max(0, deadline - time.monotonic()))[0]:
                    break
                block = os.read(self.fd, 4096)
                if not block:
                    raise OSError("The serial port disconnected.")
                self.buffer += block
                continue
            frame, self.buffer = self.buffer.split(b"\xfd", 1)
            index = frame.rfind(b"\xfe\xfe")
            if index < 0 or not frame[index:].startswith(incoming):
                continue
            body = frame[index + 4:]
            if body == b"\xfa":
                raise ValueError(f"The radio rejected command {data.hex(' ').upper()}.")
            if response is None and body == b"\xfb":
                return
            if response is not None and body.startswith(response):
                return body[len(response):]
        self.buffer = b""
        raise TimeoutError("The radio did not respond. Check the port, baud rate, and CI-V address.")


def bcd_frequency(hz):
    return bytes.fromhex(f"{hz:010d}")[::-1]


def decode_frequency(raw):
    if len(raw) != 5:
        raise ValueError("The radio returned an unexpected frequency format.")
    return int(raw[::-1].hex())


def memory_bytes(value):
    if len(value) > 70 or any(c not in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 /?,.@^*" for c in value):
        raise ValueError("A CW memory can contain up to 70 characters. Use A–Z, 0–9, spaces, or /?,.@^*.")
    return value.encode("ascii") or b" "


def cw_message(value):
    value = value.strip()
    if not value:
        raise ValueError("The CW memory is empty.")
    if "*" in value:
        raise ValueError("This memory contains a contest number (*). Send it from the radio.")
    if len(value) > 30:
        raise ValueError("CI-V can send up to 30 characters. Send longer messages from the radio.")
    return memory_bytes(value)


class Radio:
    def __init__(self, transport):
        self.transport = transport

    def command(self, data, response=None):
        return self.transport.command(data, response)

    def frequency(self):
        return decode_frequency(self.command(b"\x03", b"\x03"))

    def require_rx(self):
        if self.command(b"\x1c\x00", b"\x1c\x00") != b"\x00":
            raise ValueError("The radio is transmitting or did not report RX mode.")

    def tune(self, hz, mode):
        modes = {"LSB": (0, 0), "USB": (1, 0), "CW": (3, 0), "FT8": (1, 1)}
        code, data = modes[mode]
        self.require_rx()
        self.command(b"\x07\x00")  # Enter VFO mode and select VFO A on the IC-7300MK2.
        if mode == "FT8":
            self.command(b"\x1a\x05\x00\x85\x01")
        elif mode in ("LSB", "USB"):
            self.command(b"\x1a\x05\x00\x84\x00")
        self.command(b"\x05" + bcd_frequency(hz))
        mode_command = bytes((0x26, 0, code, data, 1))
        self.command(mode_command)
        if self.frequency() != hz or self.command(b"\x26\x00", b"\x26\x00") != mode_command[2:]:
            raise ValueError("The radio reported a different frequency or mode after tuning.")

    def read_memory(self, index):
        command = bytes((0x1a, 2, index))
        return self.command(command, command).decode("ascii").rstrip(" \x00")

    def write_memory(self, index, value):
        payload = memory_bytes(value)
        self.require_rx()
        self.command(bytes((0x1a, 2, index)) + payload)
        if self.read_memory(index) != value.rstrip():
            raise ValueError(f"M{index} did not match when read back.")

    def send_memory(self, index):
        payload = cw_message(self.read_memory(index))
        mode = self.command(b"\x04", b"\x04")
        if mode[:1] not in (b"\x03", b"\x07"):
            raise ValueError("Switch the radio to CW or CW-R before transmitting.")
        if self.command(b"\x16\x47", b"\x16\x47") not in (b"\x01", b"\x02"):
            raise ValueError("Enable BK-IN or F-BKIN on the radio before transmitting.")
        self.require_rx()
        self.command(b"\x17" + payload)

    def stop_cw(self):
        self.command(b"\x17\xff")

    def close(self):
        self.transport.close()


class Simulator:
    def __init__(self):
        self.hz = 14074000
        self.mode = "FT8"
        self.memories = ["CQ CQ DE TEST", "UR 5NN * BK", "CFM TU"] + [""] * 5

    def frequency(self):
        return self.hz

    def tune(self, hz, mode):
        self.hz, self.mode = hz, mode

    def read_memory(self, index):
        return self.memories[index - 1]

    def write_memory(self, index, value):
        memory_bytes(value)
        self.memories[index - 1] = value.rstrip()

    def send_memory(self, index):
        cw_message(self.read_memory(index))
        if self.mode != "CW":
            raise ValueError("Switch the simulator to CW before transmitting.")

    def stop_cw(self):
        pass

    def close(self):
        pass
