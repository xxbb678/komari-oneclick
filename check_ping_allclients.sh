#!/bin/bash
# Komari: 将所有 ping_tasks 设为 all_clients=1 (对所有已接入 Agent 生效)
# 即: 延迟监测任务默认在所有机器(含新机)上执行。
# 注意: 若你需要某任务仅对部分机器, 请注释本 cron (# KOMARI-V1-PINGAC) 后改 DB。
DB=/root/komari-oneclick/data/komari.db
sqlite3 "$DB" "UPDATE ping_tasks SET all_clients=1;"