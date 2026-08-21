#!/usr/bin/env python3
"""Print the frozen RTL2 capacity budget and a bank-queue smoke run."""

from __future__ import print_function

import json

from model.switch_model.capacity import analyze_capacity, simulate_line_rate


def main():
    capacity = analyze_capacity()
    bank_run = simulate_line_rate()
    payload = capacity.as_dict()
    payload["bank_simulation"] = {
        "offered_cycles": bank_run.offered_cycles,
        "total_requests": bank_run.total_requests,
        "max_backlog": bank_run.max_backlog,
        "max_bank_depth": bank_run.max_bank_depth,
        "backlog_after_offer": bank_run.backlog_after_offer,
        "drain_cycles": bank_run.drain_cycles,
        "drained": bank_run.drained,
    }
    print(json.dumps(payload, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
