#!/usr/bin/env python3
"""RS485 loopback test between the two onboard COM ports.

Sends a known ASCII string out of one port and reports what arrives on the
other, in both directions. Use it to prove the RS485 transceivers, the jumper
position and the A/B polarity without needing a real instrument on the bus.

    sudo systemctl stop signalk          # else its readers steal the bytes
    sudo python3 tools/rs485-loopback.py
    sudo systemctl start signalk

Both ends are forced to 4800 8N1 for the test: a baud mismatch would garble
the payload and tell you nothing. Signal K's own configured rates (4800 and
38400) are restored when it restarts.

Reading the result:

  data arrives, both directions  -> hardware good, polarity correct
  nothing, but tx counter climbs -> transmit works; the pair is not reaching
                                    the other receiver - check A/B, jumper
                                    position and that both data pins are
                                    actually present in the cable
  garbage arrives                -> polarity inverted or baud mismatch; swap A/B
  nothing at all, tx stays 0     -> the UART never accepted the write

History: on 2026-11-19 a null-modem cable lacking pin 1 gave tx:32/rx:0 in both
directions - nothing arrived, and the CTS/DSR that appeared on plugging it in
were handshake lines rather than the data pair. The pinout, not the software,
was the problem.
"""
import os
import select
import termios
import time

PAYLOAD = b"RS485-LOOPBACK-TEST-0123456789\r\n"
BAUD = termios.B4800
READ_S = 3.0


def open_port(dev):
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0                                   # iflag: raw
    attrs[1] = 0                                   # oflag: raw
    attrs[3] = 0                                   # lflag: raw
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[4] = BAUD
    attrs[5] = BAUD
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    time.sleep(0.2)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def drain(fd, seconds):
    got = bytearray()
    deadline = time.time() + seconds
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if fd in ready:
            try:
                got += os.read(fd, 4096)
            except OSError:
                pass
    return bytes(got)


def direction(tx_dev, rx_dev):
    print("\n  --- transmit %s  ->  receive %s ---" % (tx_dev, rx_dev))
    tx = open_port(tx_dev)
    rx = open_port(rx_dev)
    drain(rx, 0.3)
    drain(tx, 0.1)

    written = os.write(tx, PAYLOAD)
    try:
        termios.tcdrain(tx)
    except Exception:
        pass
    print("     sent %d bytes" % written)

    heard = drain(rx, READ_S)
    echo = drain(tx, 0.3)
    print("     received on %s: %d bytes" % (rx_dev, len(heard)))
    if heard:
        print("       %r" % heard[:120])
    print("     echo on %s:     %d bytes" % (tx_dev, len(echo)))

    os.close(tx)
    os.close(rx)
    return heard


def main():
    if os.geteuid() != 0:
        raise SystemExit("run as root: sudo python3 tools/rs485-loopback.py")
    a = direction("/dev/ttyS0", "/dev/ttyS1")
    b = direction("/dev/ttyS1", "/dev/ttyS0")
    print("\n  ==== verdict ====")
    print("  ttyS0 -> ttyS1 : %s" % ("DATA ARRIVED" if a else "nothing"))
    print("  ttyS1 -> ttyS0 : %s" % ("DATA ARRIVED" if b else "nothing"))


if __name__ == "__main__":
    main()
