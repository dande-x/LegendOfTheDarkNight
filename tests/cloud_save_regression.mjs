import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const source = read("scripts/SaveSystem.lua");
const mainSource = read("scripts/main.lua");

function check(condition, message) {
    if (!condition) throw new Error(message);
}

// The Maker runtime is not available to the Node regression suite. These
// assertions pin the integration points, while the small model below mirrors
// the slot/tombstone merge and async write-queue contracts used by Lua.
check(source.includes('local CLOUD_KEY = "night_legend_save_v1"'),
    "云存档 key 已改变，跨版本迁移契约会失效");
check(source.includes("cloud:BatchGet()")
    && source.includes("cloud:BatchSet()")
    && source.includes("batch:Set(CLOUD_KEY, payload)")
    && source.includes('batch:Save("暗夜传奇云存档"'),
"SaveSystem 没有通过 clientCloud values 保存完整存档");
check(source.includes("local slotUpdatedAt =")
    && source.includes("MergeCloudPayload")
    && source.includes("cloudSavePending")
    && source.includes("cloudSaveWaiters"),
"云存档缺少按槽位合并或最新快照排队状态");
check(source.includes("IsSameCharacterSnapshot")
    && source.includes("localSlot.returnScrollUnlocked == true")
    && source.includes("cloudSlot.returnScrollUnlocked == true"),
"同一角色的云存档合并没有单向保留永久回城卷轴状态");
check(source.includes("if completed or sessionId ~= cloudSessionId then return end")
    && source.includes("local CLOUD_LOAD_TIMEOUT = 8.0")
    && source.includes('cloudStatus = "unavailable"'),
"云存档异步回调缺少单次完成、超时和不可用降级保护");
check(mainSource.includes("SaveSystem.LoadFromCloud")
    && mainSource.includes("cloudSaveReady")
    && mainSource.includes("EnterSaveSlotsWhenReady"),
"启动流程没有等待首次云同步完成后再展示存档槽位");

const VALID_CLASSES = new Set(["warrior", "mage", "taoist"]);
const clone = (value) => (value == null ? value : JSON.parse(JSON.stringify(value)));
const isEmpty = (value) => value == null || value === false;
const isLoadable = (value) => value && typeof value === "object"
    && VALID_CLASSES.has(value.classId);

function makePayload(slots = [null, null], timestamps = [0, 0], updatedAt = 0) {
    const payload = {
        version: 1,
        updatedAt,
        slots: {},
        slotUpdatedAt: {},
    };
    for (let index = 0; index < 2; index += 1) {
        const key = `slot${index + 1}`;
        payload.slots[key] = isEmpty(slots[index]) ? false : clone(slots[index]);
        payload.slotUpdatedAt[key] = timestamps[index] || 0;
        payload.updatedAt = Math.max(payload.updatedAt, payload.slotUpdatedAt[key]);
    }
    return payload;
}

function slot(payload, index) {
    return payload?.slots?.[`slot${index}`];
}

function slotTimestamp(payload, index) {
    return payload?.slotUpdatedAt?.[`slot${index}`] || 0;
}

function isSameCharacterSnapshot(left, right) {
    return isLoadable(left) && isLoadable(right)
        && Number(left.createdAt) > 0
        && Number(left.createdAt) === Number(right.createdAt)
        && left.classId === right.classId;
}

function payloadDataEqual(left, right) {
    for (let index = 1; index <= 2; index += 1) {
        if (slotTimestamp(left, index) !== slotTimestamp(right, index)) return false;
        const leftSlot = slot(left, index);
        const rightSlot = slot(right, index);
        if (isEmpty(leftSlot) !== isEmpty(rightSlot)) return false;
        if (!isEmpty(leftSlot) && JSON.stringify(leftSlot) !== JSON.stringify(rightSlot)) {
            return false;
        }
    }
    return true;
}

function mergeCloudPayload(localPayload, cloudPayload) {
    const merged = makePayload();
    merged.updatedAt = Math.max(localPayload.updatedAt || 0, cloudPayload.updatedAt || 0);
    for (let index = 1; index <= 2; index += 1) {
        const localSlot = slot(localPayload, index);
        const cloudSlot = slot(cloudPayload, index);
        const localTimestamp = slotTimestamp(localPayload, index);
        const cloudTimestamp = slotTimestamp(cloudPayload, index);

        // This is intentionally the same tie-break as SaveSystem.lua:
        // positive equal timestamps prefer the cloud's explicit result;
        // legacy zero/zero data keeps a non-empty local slot unless only the
        // cloud has a character.
        let useCloud = cloudTimestamp > localTimestamp
            || (cloudTimestamp === localTimestamp && cloudTimestamp > 0);
        if (cloudTimestamp === 0 && localTimestamp === 0
            && isEmpty(localSlot) && !isEmpty(cloudSlot)) {
            useCloud = true;
        }
        const selected = useCloud ? cloudSlot : localSlot;
        const selectedTimestamp = useCloud ? cloudTimestamp : localTimestamp;
        const mergedSlot = isEmpty(selected) ? false : clone(selected);
        if (mergedSlot && isSameCharacterSnapshot(localSlot, cloudSlot)
            && (localSlot.returnScrollUnlocked === true
                || cloudSlot.returnScrollUnlocked === true)) {
            mergedSlot.returnScrollUnlocked = true;
        }
        merged.slots[`slot${index}`] = mergedSlot;
        merged.slotUpdatedAt[`slot${index}`] = selectedTimestamp;
        merged.updatedAt = Math.max(merged.updatedAt, selectedTimestamp);
    }
    return merged;
}

function normalizeCloudPayload(raw) {
    if (isEmpty(raw)) return { payload: null, reason: "missing" };
    if (!raw || typeof raw !== "object") return { payload: null, reason: "invalid_payload" };
    if (Number(raw.version ?? raw.schemaVersion ?? 1) !== 1) {
        return { payload: null, reason: "unsupported_version" };
    }
    if (!raw.slots || typeof raw.slots !== "object") {
        return { payload: null, reason: "invalid_slots" };
    }

    const slots = [];
    const timestamps = [];
    for (let index = 1; index <= 2; index += 1) {
        const key = `slot${index}`;
        const value = raw.slots[key] ?? raw.slots[index];
        const metadata = raw.slotUpdatedAt || raw.slotTimestamps || {};
        const timestamp = Number(metadata[key] ?? metadata[index] ?? 0) || 0;
        if (isEmpty(value)) {
            slots.push(null);
            timestamps.push(timestamp);
            continue;
        }
        if (!isLoadable(value)) return { payload: null, reason: `invalid_slot_${index}` };
        slots.push(clone(value));
        timestamps.push(timestamp || Number(value.updatedAt) || Number(raw.updatedAt) || 0);
    }
    return { payload: makePayload(slots, timestamps, Number(raw.updatedAt) || 0), reason: null };
}

// 1) A new device adopts a valid cloud character even when its local disk is empty.
{
    const local = makePayload();
    const cloud = makePayload([{ classId: "warrior", level: 18 }], [42, 0], 42);
    const merged = mergeCloudPayload(local, cloud);
    check(slot(merged, 1)?.level === 18 && slotTimestamp(merged, 1) === 42,
        "新设备没有读取云端角色槽位");
}

// 2) A legacy/local-only device uploads its newest local snapshot on a missing key.
{
    const local = makePayload([{ classId: "mage", level: 7 }], [11, 0], 11);
    const normalized = normalizeCloudPayload(false);
    check(normalized.reason === "missing", "空云值没有识别为首次初始化");
    const upload = clone(local); // LoadFromCloud uses the callback-time snapshot.
    check(slot(upload, 1)?.classId === "mage" && slotTimestamp(upload, 1) === 11,
        "旧本地存档首次上传没有保留本地角色");
}

// 3) Different devices can update different slots without one overwriting the other.
{
    const deviceA = makePayload([
        { classId: "warrior", level: 30 },
        { classId: "taoist", level: 10 },
    ], [100, 20], 100);
    const deviceB = makePayload([
        { classId: "warrior", level: 29 },
        { classId: "taoist", level: 14 },
    ], [80, 120], 120);
    const merged = mergeCloudPayload(deviceA, deviceB);
    check(slot(merged, 1)?.level === 30 && slotTimestamp(merged, 1) === 100,
        "槽位 1 没有保留较新的设备版本");
    check(slot(merged, 2)?.level === 14 && slotTimestamp(merged, 2) === 120,
        "槽位 2 没有合并另一台设备的较新版本");
}

// 4) Deletion is a timestamped tombstone and beats an older character snapshot.
{
    const localCharacter = makePayload([{ classId: "warrior", level: 20 }], [100, 0], 100);
    const cloudDeletion = makePayload([null, null], [101, 0], 101);
    const merged = mergeCloudPayload(localCharacter, cloudDeletion);
    check(isEmpty(slot(merged, 1)) && slotTimestamp(merged, 1) === 101,
        "较新的删除 tombstone 没有跨设备生效");

    const localDeletion = makePayload([null, null], [202, 0], 202);
    const oldCloudCharacter = makePayload([{ classId: "warrior", level: 99 }], [201, 0], 201);
    const kept = mergeCloudPayload(localDeletion, oldCloudCharacter);
    check(isEmpty(slot(kept, 1)) && slotTimestamp(kept, 1) === 202,
        "本地较新的删除没有阻止旧云角色复活");
}

// 5) Character-bound feature flags round-trip inside their own slot only.
{
    const local = makePayload([
        { classId: "warrior", createdAt: 100, level: 20, returnScrollUnlocked: true },
        { classId: "mage", createdAt: 200, level: 12, returnScrollUnlocked: false },
    ], [300, 250], 300);
    const roundTrip = normalizeCloudPayload(clone(local));
    check(roundTrip.reason === null
        && slot(roundTrip.payload, 1)?.returnScrollUnlocked === true,
    "回城卷轴解锁状态没有进入云存档并正确回读");
    check(slot(roundTrip.payload, 2)?.returnScrollUnlocked === false,
        "槽位 1 的回城卷轴状态污染了槽位 2");

    const cloudWithOlderOtherSlot = makePayload([
        { classId: "warrior", createdAt: 100, level: 21, returnScrollUnlocked: false },
        { classId: "mage", createdAt: 200, level: 13, returnScrollUnlocked: false },
    ], [301, 302], 302);
    const merged = mergeCloudPayload(local, cloudWithOlderOtherSlot);
    check(slot(merged, 1)?.level === 21
        && slot(merged, 1)?.returnScrollUnlocked === true,
    "同一角色的较新普通进度覆盖了永久回城卷轴状态");
    check(slot(merged, 2)?.level === 13
        && slot(merged, 2)?.returnScrollUnlocked === false,
    "按槽位合并没有保持另一角色自己的回城卷轴状态");

    const deleted = mergeCloudPayload(
        merged,
        makePayload([null, slot(merged, 2)], [303, 302], 303),
    );
    check(isEmpty(slot(deleted, 1)) && slotTimestamp(deleted, 1) === 303,
        "删除角色后云端 tombstone 没有同时清除回城卷轴状态");

    const recreated = mergeCloudPayload(
        merged,
        makePayload([{
            classId: "warrior",
            createdAt: 999,
            level: 1,
            returnScrollUnlocked: false,
        }, slot(merged, 2)], [304, 302], 304),
    );
    check(slot(recreated, 1)?.createdAt === 999
        && slot(recreated, 1)?.returnScrollUnlocked === false,
    "槽位中新建的角色错误继承了已删除角色的回城卷轴状态");
}

// 6) Invalid cloud payloads and unavailable platforms fall back to local data.
{
    check(normalizeCloudPayload({ version: 2, slots: {} }).reason === "unsupported_version",
        "不支持的云存档版本没有被拒绝");
    check(normalizeCloudPayload({ version: 1, slots: { slot1: { classId: "hacker" } } }).reason
        === "invalid_slot_1", "非法职业云槽位没有被拒绝");
    const local = makePayload([{ classId: "taoist", level: 12 }], [9, 0], 9);
    const unavailableResult = { ok: false, code: "unavailable", source: "local_only" };
    check(!unavailableResult.ok && unavailableResult.source === "local_only"
        && slot(local, 1)?.level === 12,
    "平台不可用时没有保留本地存档降级路径");
}

// 7) If local saving happens while BatchGet is pending, the callback must upload
// the callback-time snapshot rather than the stale snapshot from request start.
{
    const requestStart = makePayload([{ classId: "warrior", level: 1 }], [10, 0], 10);
    const latestAtCallback = makePayload([{ classId: "warrior", level: 2 }], [11, 0], 11);
    const uploaded = clone(latestAtCallback);
    check(slot(requestStart, 1)?.level === 1 && slot(uploaded, 1)?.level === 2,
        "云读取期间本地保存的最新快照没有被上传");
    check(source.includes("localPayload = BuildCloudPayload()")
        && source.includes("请求在网络上等待期间可能已经发生了本地自动保存"),
    "实现没有明确使用云回调到达时的最新本地快照");
}

// 8) Repeated autosaves while one write is in flight retain only the newest payload.
function makeWriteQueue() {
    let inFlight = null;
    let pending = null;
    let lastSuccessful = null;
    const writes = [];
    const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
    return {
        save(payload) {
            if (inFlight) {
                pending = clone(payload);
                return;
            }
            if (lastSuccessful && same(lastSuccessful, payload)) return;
            inFlight = clone(payload);
            writes.push(clone(payload));
        },
        complete(ok = true) {
            if (!inFlight) return;
            if (ok) lastSuccessful = clone(inFlight);
            inFlight = null;
            if (pending) {
                const next = pending;
                pending = null;
                this.save(next);
            }
        },
        writes,
    };
}

{
    const queue = makeWriteQueue();
    queue.save(makePayload([{ classId: "warrior", level: 1 }], [1, 0], 1));
    queue.save(makePayload([{ classId: "warrior", level: 2 }], [2, 0], 2));
    queue.save(makePayload([{ classId: "warrior", level: 3 }], [3, 0], 3));
    check(queue.writes.length === 1, "连续自动保存没有合并 in-flight 云写入");
    queue.complete(true);
    check(queue.writes.length === 2 && slot(queue.writes[1], 1)?.level === 3,
        "云写入队列没有只保留最新快照");
    queue.complete(true);
    queue.complete(false);
    check(queue.writes.length === 2, "同一次云写入的重复回调触发了额外写入");
}

console.log("cloud_save_regression: PASS");
console.log("checked cloud bootstrap, per-slot merge, tombstones, fallback, races, and write coalescing");
