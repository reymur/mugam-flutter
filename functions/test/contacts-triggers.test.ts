import { getAdminApp, db, clearFirestore, waitFor, docExists } from "./helpers";

beforeAll(() => {
  getAdminApp();
});

beforeEach(async () => {
  await clearFirestore();
});

function contactPairExists(a: string, b: string): Promise<boolean> {
  return docExists(`users/${a}/contacts/${b}`);
}

async function allExist(pairs: Array<[string, string]>): Promise<boolean> {
  const results = await Promise.all(pairs.map(([a, b]) => contactPairExists(a, b)));
  return results.every(Boolean);
}

async function allAbsent(pairs: Array<[string, string]>): Promise<boolean> {
  const results = await Promise.all(pairs.map(([a, b]) => contactPairExists(a, b)));
  return results.every((exists) => !exists);
}

// 1. onChatCreated — group chat creation
test("onChatCreated upserts all 6 contact-pair docs for a 3-member group", async () => {
  const chatRef = db().collection("chats").doc();
  await chatRef.set({
    isGroup: true,
    name: "Test Group",
    members: ["A", "B", "C"],
    admins: ["A"],
    createdBy: "A",
  });

  const allPairs: Array<[string, string]> = [
    ["A", "B"], ["B", "A"],
    ["A", "C"], ["C", "A"],
    ["B", "C"], ["C", "B"],
  ];

  await waitFor(() => allExist(allPairs));

  for (const [a, b] of allPairs) {
    expect(await contactPairExists(a, b)).toBe(true);
  }
});

// 2. onChatUpdated — member removal with a surviving shared chat
test("onChatUpdated: removing C from chat1 deletes A-C/B-C but NOT A-B (still shared via chat2)", async () => {
  const chat1 = db().collection("chats").doc();
  const chat2 = db().collection("chats").doc();
  await chat1.set({ isGroup: true, members: ["A", "B", "C"] });
  await chat2.set({ isGroup: true, members: ["A", "B"] });

  // Let both onChatCreated triggers settle before the update action.
  await waitFor(() => allExist([["A", "B"], ["A", "C"], ["B", "C"]]));

  await chat1.update({ members: ["A", "B"] });

  await waitFor(() => allAbsent([["A", "C"], ["C", "A"], ["B", "C"], ["C", "B"]]));

  expect(await contactPairExists("A", "C")).toBe(false);
  expect(await contactPairExists("C", "A")).toBe(false);
  expect(await contactPairExists("B", "C")).toBe(false);
  expect(await contactPairExists("C", "B")).toBe(false);
  // The critical "don't over-delete" assertion:
  expect(await contactPairExists("A", "B")).toBe(true);
  expect(await contactPairExists("B", "A")).toBe(true);
});

// 3. onChatUpdated — member removal with NO surviving shared chat
test("onChatUpdated: removing B from a single [A,B] chat deletes the A-B pair entirely", async () => {
  const chat = db().collection("chats").doc();
  await chat.set({ isGroup: false, members: ["A", "B"] });

  await waitFor(() => allExist([["A", "B"]]));

  await chat.update({ members: ["A"] });

  await waitFor(() => allAbsent([["A", "B"], ["B", "A"]]));

  expect(await contactPairExists("A", "B")).toBe(false);
  expect(await contactPairExists("B", "A")).toBe(false);
});

// 4. onChatDeleted — full group deletion, no other chats connect the members
test("onChatDeleted: deleting the only chat between A/B/C removes all 3 pairs both ways", async () => {
  const chat = db().collection("chats").doc();
  await chat.set({ isGroup: true, members: ["A", "B", "C"] });

  const allPairs: Array<[string, string]> = [
    ["A", "B"], ["B", "A"],
    ["A", "C"], ["C", "A"],
    ["B", "C"], ["C", "B"],
  ];
  await waitFor(() => allExist(allPairs));

  await chat.delete();

  await waitFor(() => allAbsent(allPairs));

  for (const [a, b] of allPairs) {
    expect(await contactPairExists(a, b)).toBe(false);
  }
});

// 5. onChatDeleted — full group deletion with a surviving shared chat
test("onChatDeleted: deleting chat1 [A,B,C] removes A-C/B-C but NOT A-B (still shared via chat2)", async () => {
  const chat1 = db().collection("chats").doc();
  const chat2 = db().collection("chats").doc();
  await chat1.set({ isGroup: true, members: ["A", "B", "C"] });
  await chat2.set({ isGroup: true, members: ["A", "B"] });

  await waitFor(() => allExist([["A", "B"], ["A", "C"], ["B", "C"]]));

  await chat1.delete();

  await waitFor(() => allAbsent([["A", "C"], ["C", "A"], ["B", "C"], ["C", "B"]]));

  expect(await contactPairExists("A", "C")).toBe(false);
  expect(await contactPairExists("C", "A")).toBe(false);
  expect(await contactPairExists("B", "C")).toBe(false);
  expect(await contactPairExists("C", "B")).toBe(false);
  expect(await contactPairExists("A", "B")).toBe(true);
  expect(await contactPairExists("B", "A")).toBe(true);
});
