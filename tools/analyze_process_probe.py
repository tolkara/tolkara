#!/usr/bin/env python3
"""Summarize one host run; this measures IPC continuity, not Steam feasibility."""
import argparse
import json
import re
from pathlib import Path

RUN = re.compile(r'^=== run (\S+) at (.+)$', re.M)
PING = re.compile(r'^(\S+) ping (\d+) at \+([\d.]+) s host (\w+): (.*)$')
PONG = re.compile(r'^pong \S+ pid (\d+) uptime [\d.]+ phase background \(')


def summarize(text):
    starts = list(RUN.finditer(text))
    if not starts:
        raise ValueError('No host run marker; cannot establish observation scope')
    start = starts[-1]
    rows = text[start.end():].splitlines()
    longest = 0.0
    streak_start = previous = None
    peer_pid = None
    observed = qualified = failures = gaps = 0
    last_time = None
    for line in rows:
        match = PING.match(line)
        if not match:
            continue
        stamp, sequence, elapsed, phase, answer = match.groups()
        elapsed = float(elapsed)
        observed += 1
        last_time = stamp
        pong = PONG.match(answer)
        eligible = phase == 'active' and pong is not None
        if not answer.startswith('pong '):
            failures += 1
        if not eligible:
            streak_start = previous = peer_pid = None
            continue
        qualified += 1
        pid = int(pong[1])
        sequence = int(sequence)
        continuous = (previous is not None and pid == peer_pid
                      and sequence == previous[0] + 1
                      and 0 <= elapsed - previous[1] <= 10)
        if not continuous:
            if previous is not None:
                gaps += 1
            streak_start = elapsed
        longest = max(longest, elapsed - streak_start)
        previous, peer_pid = (sequence, elapsed), pid
    return dict(run=start[1], started=start[2], last_observed=last_time,
                requests=observed, active_host_background_peer_replies=qualified,
                failed_requests=failures, continuity_breaks=gaps,
                longest_observed_background_seconds=round(longest, 1),
                host_finished='pings done' in rows,
                scope='Light IPC only; log freshness and task completion require separate verification')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host_log', type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.host_log.read_text()), indent=2))
