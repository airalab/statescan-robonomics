#!/usr/bin/env bash
# statescan indexer heights + chain finalized height, container resources and Mongo sizes
# -> node_exporter textfile (run from /etc/cron.d/statescan-metrics).
# On failure the old file stays, so statescan_metrics_last_success_timestamp_seconds goes stale -> alert.
set -u
OUT="${OUT:-/var/lib/node_exporter/statescan.prom}"
RPC="${RPC:?set RPC to the HTTP RPC of the archive node, e.g. http://<node-ip>:9944}"
TMP="$OUT.$$"
trap 'rm -f "$TMP"' EXIT

fin_hex=$(curl -sf -m 10 -H 'Content-Type: application/json' \
  -d '{"id":1,"jsonrpc":"2.0","method":"chain_getFinalizedHead"}' "$RPC" | sed -E 's/.*"result":"([^"]+)".*/\1/') || fin_hex=""
fin_num=""
if [ -n "$fin_hex" ]; then
  fin_num=$(curl -sf -m 10 -H 'Content-Type: application/json' \
    -d "{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"chain_getHeader\",\"params\":[\"$fin_hex\"]}" "$RPC" \
    | sed -E 's/.*"number":"0x([0-9a-f]+)".*/\1/') && fin_num=$((16#$fin_num))
fi

heights=$(docker exec statescan-mongodb mongosh --quiet --eval '
  for (const s of ["block","account","runtime","multisig","proxy","vesting"]) {
    const d = db.getSiblingDB("statescan-robonomics-" + s).status.findOne({ name: "main-scan-height" });
    print(s + " " + (d ? d.value : -1));
  }' 2>/dev/null) || heights=""

# "<db> <sizeOnDisk>" and "<db> <collection> <count>" for the dashboard; optional, a failure leaves them out
mongo_stats=$(docker exec statescan-mongodb mongosh --quiet --eval '
  const counted = { block: ["block","extrinsic","event","call","transfer"], account: ["address"],
                    multisig: ["multisig"], vesting: ["vesting"] };
  for (const d of db.adminCommand({ listDatabases: 1 }).databases) {
    if (!d.name.startsWith("statescan-robonomics-")) continue;
    const short = d.name.slice("statescan-robonomics-".length);
    print("size " + short + " " + d.sizeOnDisk);
    for (const c of counted[short] || [])
      print("docs " + short + " " + c + " " + db.getSiblingDB(d.name)[c].estimatedDocumentCount());
  }' 2>/dev/null) || mongo_stats=""

# RWS usage from indexed events (index section+method+blockHeight; never query event/extrinsic without it — a
# collection scan of the 13 GB block DB OOM-kills mongod at its 4g limit). "total <n>" and
# "calls <subscription> <device> <call> <ok|error> <n>" for the last 14400 blocks (~24 h). Optional.
rws_stats=$(docker exec statescan-mongodb mongosh --quiet statescan-robonomics-block --eval '
  const f = { section: "rws", method: "NewCall" };
  print("total " + db.event.countDocuments(f));
  const h = db.status.findOne({ name: "main-scan-height" }).value;
  db.event.aggregate([
    { $match: { ...f, "indexer.blockHeight": { $gt: h - 14400 } } },
    { $lookup: { from: "extrinsic", let: { bh: "$indexer.blockHeight", ei: "$indexer.extrinsicIndex" },
        pipeline: [
          { $match: { $expr: { $and: [{ $eq: ["$indexer.blockHeight", "$$bh"] }, { $eq: ["$indexer.extrinsicIndex", "$$ei"] }] } } },
          { $project: { _id: 0, sub: { $arrayElemAt: ["$call.args.value", 0] },
              call: { $concat: [{ $arrayElemAt: ["$call.args.value.section", 0] }, ".", { $arrayElemAt: ["$call.args.value.method", 0] }] } } }],
        as: "x" } },
    { $project: { device: { $arrayElemAt: ["$args.value", 0] }, sub: { $arrayElemAt: ["$x.sub", 0] }, call: { $arrayElemAt: ["$x.call", 0] },
        result: { $cond: [{ $eq: [{ $type: { $getField: { field: "ok", input: { $arrayElemAt: ["$args.value", 1] } } } }, "missing"] }, "error", "ok"] } } },
    { $group: { _id: { sub: "$sub", device: "$device", call: "$call", result: "$result" }, n: { $sum: 1 } } },
  ]).forEach(g => print(["calls", g._id.sub, g._id.device, g._id.call || "unknown", g._id.result, g.n].join(" ")));
' 2>/dev/null) || rws_stats=""

# "<name> <running 0|1> <restarts> <mem bytes> <mem limit> <cpu usec>" per compose container (cgroup v2)
containers=$(docker ps -a --filter label=com.docker.compose.project=statescan \
  --format '{{.Names}}' | xargs -r docker inspect -f '{{.Name}} {{.State.Running}} {{.RestartCount}} {{.Id}}' \
  | while read -r name running restarts id; do
      cg=/sys/fs/cgroup/system.slice/docker-$id.scope
      mem=$(cat "$cg/memory.current" 2>/dev/null || echo 0)
      lim=$(cat "$cg/memory.max" 2>/dev/null || echo 0); [ "$lim" = max ] && lim=0
      cpu=$(awk '$1=="usage_usec"{print $2}' "$cg/cpu.stat" 2>/dev/null); cpu=${cpu:-0}
      [ "$running" = true ] && running=1 || running=0
      echo "${name#/statescan-} $running $restarts $mem $lim $cpu"
    done)

if [ -z "$fin_num" ] || [ -z "$heights" ]; then
  logger -t statescan-metrics "failed: finalized='$fin_num' heights='${heights//$'\n'/ }'"
  exit 1
fi

{
  echo "# HELP statescan_chain_finalized_height Finalized height of Robonomics Polkadot from the archive node"
  echo "# TYPE statescan_chain_finalized_height gauge"
  echo "statescan_chain_finalized_height $fin_num"
  echo "# HELP statescan_scan_height Last block processed by a statescan indexer"
  echo "# TYPE statescan_scan_height gauge"
  while read -r name h; do echo "statescan_scan_height{scanner=\"$name\"} $h"; done <<< "$heights"
  echo "# HELP statescan_container_running 1 if the statescan container is running"
  echo "# TYPE statescan_container_running gauge"
  echo "# HELP statescan_container_restarts Docker restart count of the container"
  echo "# TYPE statescan_container_restarts gauge"
  echo "# HELP statescan_container_memory_bytes Container cgroup memory usage"
  echo "# TYPE statescan_container_memory_bytes gauge"
  echo "# HELP statescan_container_memory_limit_bytes Container mem_limit (0 = none)"
  echo "# TYPE statescan_container_memory_limit_bytes gauge"
  echo "# HELP statescan_container_cpu_seconds_total Container cgroup CPU time"
  echo "# TYPE statescan_container_cpu_seconds_total counter"
  while read -r name running restarts mem lim cpu; do
    [ -n "$name" ] || continue
    l="{container=\"$name\"}"
    echo "statescan_container_running$l $running"
    echo "statescan_container_restarts$l $restarts"
    echo "statescan_container_memory_bytes$l $mem"
    echo "statescan_container_memory_limit_bytes$l $lim"
    echo "statescan_container_cpu_seconds_total$l $(awk -v u="$cpu" 'BEGIN{printf "%.3f", u/1e6}')"
  done <<< "$containers"
  echo "# HELP statescan_mongo_db_size_bytes MongoDB sizeOnDisk of a statescan database"
  echo "# TYPE statescan_mongo_db_size_bytes gauge"
  echo "# HELP statescan_mongo_documents Estimated document count of a statescan collection"
  echo "# TYPE statescan_mongo_documents gauge"
  while read -r kind a b c; do
    case "$kind" in
      size) echo "statescan_mongo_db_size_bytes{db=\"$a\"} $b" ;;
      docs) echo "statescan_mongo_documents{db=\"$a\",collection=\"$b\"} $c" ;;
    esac
  done <<< "$mongo_stats"
  echo "# HELP statescan_rws_calls_total rws.NewCall events since genesis (calls made through an RWS subscription)"
  echo "# TYPE statescan_rws_calls_total counter"
  echo "# HELP statescan_rws_calls_24h rws.call by subscription, device, inner call and result in the last 14400 blocks"
  echo "# TYPE statescan_rws_calls_24h gauge"
  while read -r kind a b c d e; do
    case "$kind" in
      total) echo "statescan_rws_calls_total $a" ;;
      calls) echo "statescan_rws_calls_24h{subscription=\"$a\",device=\"$b\",call=\"$c\",result=\"$d\"} $e" ;;
    esac
  done <<< "$rws_stats"
  echo "# HELP statescan_metrics_last_success_timestamp_seconds Unix time of last successful metrics run"
  echo "# TYPE statescan_metrics_last_success_timestamp_seconds gauge"
  echo "statescan_metrics_last_success_timestamp_seconds $(date +%s)"
} > "$TMP" && chmod 644 "$TMP" && mv "$TMP" "$OUT"
