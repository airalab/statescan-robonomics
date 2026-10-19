// Seed the runtime DB without querying the runtime version of every block.
//
// The regular scan calls state_getRuntimeVersion for each historical block, which on an
// archive node executes the runtime at that block's state: millions of wasm calls. Runtime
// versions only change on upgrades, so find the change heights by bisection instead, store
// them in the same format as the scan does, and move the scan height to the finalized head
// so the regular scan continues from there.
require("dotenv").config();

const { getRuntimeVersion } = require("../common/queryRuntime");
const { getMetadata } = require("../common/queryMetadata");
const { batchInsertVersions } = require("../common/batchInsert");
const { extractDifferentVersions } = require("../scan/versions");
const {
  chain: { getApi },
} = require("@osn/scan-common");
const {
  runtime: { initRuntimeScanDb, getRuntimeDb, getRuntimeCollection },
} = require("@statescan/mongo");

const genesisHeight = 1;

function sameVersion(a, b) {
  return extractDifferentVersions([{ runtimeVersion: b }], a).length === 0;
}

// Heights in (lo, hi] where the version differs from the one at the previous height.
async function findChanges(lo, loVersion, hi, hiVersion, result) {
  if (sameVersion(loVersion, hiVersion)) {
    return;
  }
  if (hi - lo === 1) {
    result.push({ height: hi, runtimeVersion: hiVersion });
    return;
  }

  const mid = Math.floor((lo + hi) / 2);
  const { runtimeVersion: midVersion } = await getRuntimeVersion(mid);
  await findChanges(lo, loVersion, mid, midVersion, result);
  await findChanges(mid, midVersion, hi, hiVersion, result);
}

async function main() {
  await initRuntimeScanDb();
  const api = await getApi();

  const finalizedHash = await api.rpc.chain.getFinalizedHead();
  const finalized = (await api.rpc.chain.getHeader(finalizedHash)).number.toNumber();

  const first = await getRuntimeVersion(genesisHeight);
  const last = await getRuntimeVersion(finalized);
  const changes = [];
  await findChanges(
    genesisHeight,
    first.runtimeVersion,
    finalized,
    last.runtimeVersion,
    changes,
  );

  const versions = [first, ...changes];
  const toSave = [];
  for (const version of versions) {
    const metadata = await getMetadata(version.height);
    toSave.push({ ...version, metadata });
    const { specName, specVersion } = version.runtimeVersion;
    console.log(`${version.height}: ${specName} v${specVersion}`);
  }

  const col = await getRuntimeCollection();
  await col.deleteMany({});
  await batchInsertVersions(toSave);
  await getRuntimeDb().updateScanHeight(finalized);

  console.log(`Saved ${toSave.length} versions, scan height set to ${finalized}`);
  process.exit(0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
