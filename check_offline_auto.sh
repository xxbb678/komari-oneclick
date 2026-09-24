#!/bin/bash
# Komari: 新接入 Agent 自动开启离线通知 (enable=1, grace=180s)
# 幂等: 仅针对"已存在 client 但尚无 offline_notifications 记录"的机器插入, 不覆盖用户手动关闭的机器
DB=/root/komari-oneclick/data/komari.db
sqlite3 "$DB" "INSERT OR IGNORE INTO offline_notifications (client, enable, grace_period)
  SELECT uuid, 1, 180 FROM clients
  WHERE uuid NOT IN (SELECT client FROM offline_notifications);"