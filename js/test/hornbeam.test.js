/**
 * Tests for hornbeam.js client
 *
 * Run with: node hornbeam.test.js
 */

// Simple test framework
const tests = [];
let passed = 0;
let failed = 0;

function test(name, fn) {
  tests.push({ name, fn });
}

function assertEqual(actual, expected, msg = "") {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `${msg}\nExpected: ${JSON.stringify(expected)}\nActual: ${JSON.stringify(actual)}`
    );
  }
}

function assertTrue(value, msg = "") {
  if (!value) {
    throw new Error(`Expected truthy value: ${msg}`);
  }
}

function assertFalse(value, msg = "") {
  if (value) {
    throw new Error(`Expected falsy value: ${msg}`);
  }
}

async function runTests() {
  console.log("\nRunning hornbeam.js tests...\n");

  for (const { name, fn } of tests) {
    try {
      await fn();
      console.log(`  ✓ ${name}`);
      passed++;
    } catch (error) {
      console.log(`  ✗ ${name}`);
      console.log(`    ${error.message}`);
      failed++;
    }
  }

  console.log(`\n${passed} passed, ${failed} failed\n`);
  process.exit(failed > 0 ? 1 : 0);
}

// Load module
const { Socket, Channel, Push, Presence, Timer } = require("../hornbeam.js");

// Mock WebSocket for testing
class MockWebSocket {
  constructor(url) {
    this.url = url;
    this.readyState = 0; // CONNECTING
    this.binaryType = "blob";
    this.sentMessages = [];

    // Simulate open after next tick
    setTimeout(() => {
      this.readyState = 1; // OPEN
      if (this.onopen) this.onopen();
    }, 0);
  }

  send(data) {
    this.sentMessages.push(data);
  }

  close(code, reason) {
    this.readyState = 3; // CLOSED
    if (this.onclose) {
      this.onclose({ code: code || 1000, reason: reason || "" });
    }
  }

  // Test helpers
  simulateMessage(data) {
    if (this.onmessage) {
      this.onmessage({ data: JSON.stringify(data) });
    }
  }

  simulateError(error) {
    if (this.onerror) {
      this.onerror(error);
    }
  }
}

// =============================================================================
// Timer Tests
// =============================================================================

test("Timer - schedules timeout", (done) => {
  return new Promise((resolve) => {
    let called = false;
    const timer = new Timer(
      () => {
        called = true;
        resolve();
      },
      () => 10
    );
    timer.scheduleTimeout();
    setTimeout(() => {
      assertTrue(called, "Timer should have been called");
      resolve();
    }, 50);
  });
});

test("Timer - reset clears timeout", () => {
  return new Promise((resolve) => {
    let called = false;
    const timer = new Timer(
      () => {
        called = true;
      },
      () => 50
    );
    timer.scheduleTimeout();
    timer.reset();
    setTimeout(() => {
      assertFalse(called, "Timer should not have been called after reset");
      resolve();
    }, 100);
  });
});

test("Timer - tracks tries", () => {
  return new Promise((resolve) => {
    const tries = [];
    const timer = new Timer(
      () => {
        tries.push(timer.tries);
        if (timer.tries < 3) {
          timer.scheduleTimeout();
        } else {
          assertEqual(tries, [1, 2, 3]);
          resolve();
        }
      },
      () => 5
    );
    timer.scheduleTimeout();
  });
});

// =============================================================================
// Socket Tests
// =============================================================================

test("Socket - constructs with endpoint", () => {
  const socket = new Socket("/ws", { transport: MockWebSocket });
  assertTrue(socket.endPointURL().includes("/ws"), "Should include endpoint");
});

test("Socket - appends params to URL", () => {
  const socket = new Socket("/ws", {
    transport: MockWebSocket,
    params: { token: "abc123" },
  });
  const url = socket.endPointURL();
  assertTrue(url.includes("token=abc123"), "Should include token param");
});

test("Socket - creates channels", () => {
  const socket = new Socket("/ws", { transport: MockWebSocket });
  const channel = socket.channel("room:lobby", { user: "alice" });
  assertTrue(channel instanceof Channel, "Should return Channel instance");
  assertEqual(channel.topic, "room:lobby");
});

test("Socket - tracks multiple channels", () => {
  const socket = new Socket("/ws", { transport: MockWebSocket });
  socket.channel("room:1");
  socket.channel("room:2");
  assertEqual(socket.channels.length, 2);
});

test("Socket - makeRef increments", () => {
  const socket = new Socket("/ws", { transport: MockWebSocket });
  const ref1 = socket.makeRef();
  const ref2 = socket.makeRef();
  assertTrue(parseInt(ref2) > parseInt(ref1), "Refs should increment");
});

test("Socket - connectionState reflects WebSocket state", () => {
  const socket = new Socket("/ws", { transport: MockWebSocket });
  assertEqual(socket.connectionState(), "closed");

  socket.connect();
  // MockWebSocket starts as CONNECTING (0)
  assertEqual(socket.connectionState(), "connecting");
});

test("Socket - isConnected returns false when closed", () => {
  const socket = new Socket("/ws", { transport: MockWebSocket });
  assertFalse(socket.isConnected());
});

// =============================================================================
// Channel Tests
// =============================================================================

test("Channel - initializes with topic and params", () => {
  const socket = new Socket("/ws", { transport: MockWebSocket });
  const channel = socket.channel("room:lobby", { key: "value" });

  assertEqual(channel.topic, "room:lobby");
  assertEqual(channel.params, { key: "value" });
  assertEqual(channel.state, "closed");
});

test("Channel - join returns Push", () => {
  const socket = new Socket("/ws", { transport: MockWebSocket });
  const channel = socket.channel("room:lobby");
  const push = channel.join();

  assertTrue(push instanceof Push, "join() should return Push");
});

test("Channel - join can only be called once", () => {
  const socket = new Socket("/ws", { transport: MockWebSocket });
  const channel = socket.channel("room:lobby");
  channel.join();

  try {
    channel.join();
    throw new Error("Should have thrown");
  } catch (e) {
    assertTrue(e.message.includes("multiple times"));
  }
});

test("Channel - state transitions to joining", () => {
  const socket = new Socket("/ws", { transport: MockWebSocket });
  socket.connect();

  return new Promise((resolve) => {
    socket.onOpen(() => {
      const channel = socket.channel("room:lobby");
      channel.join();
      assertEqual(channel.state, "joining");
      resolve();
    });
  });
});

test("Channel - on registers event handler", () => {
  const socket = new Socket("/ws", { transport: MockWebSocket });
  const channel = socket.channel("room:lobby");

  let received = null;
  channel.on("new_msg", (payload) => {
    received = payload;
  });

  channel.trigger("new_msg", { body: "hello" });
  assertEqual(received, { body: "hello" });
});

test("Channel - off removes event handler", () => {
  const socket = new Socket("/ws", { transport: MockWebSocket });
  const channel = socket.channel("room:lobby");

  let callCount = 0;
  const ref = channel.on("event", () => {
    callCount++;
  });

  channel.trigger("event", {});
  assertEqual(callCount, 1);

  channel.off("event", ref);
  channel.trigger("event", {});
  assertEqual(callCount, 1, "Handler should not be called after off()");
});

test("Channel - isClosed returns correct state", () => {
  const socket = new Socket("/ws", { transport: MockWebSocket });
  const channel = socket.channel("room:lobby");

  assertTrue(channel.isClosed());
  assertFalse(channel.isJoined());
  assertFalse(channel.isJoining());
});

// =============================================================================
// Push Tests
// =============================================================================

test("Push - receive registers callback", () => {
  const socket = new Socket("/ws", { transport: MockWebSocket });
  const channel = socket.channel("room:lobby");
  channel.joinedOnce = true; // Skip join check

  const push = channel.push("event", {});

  let okCalled = false;
  let errorCalled = false;

  push.receive("ok", () => {
    okCalled = true;
  });
  push.receive("error", () => {
    errorCalled = true;
  });

  // Simulate ok response
  push.trigger("ok", { data: "test" });

  assertTrue(okCalled, "ok callback should be called");
  assertFalse(errorCalled, "error callback should not be called");
});

test("Push - receive chains", () => {
  const socket = new Socket("/ws", { transport: MockWebSocket });
  const channel = socket.channel("room:lobby");
  channel.joinedOnce = true;

  const push = channel.push("event", {});

  const result = push.receive("ok", () => {}).receive("error", () => {});

  assertTrue(result === push, "receive() should return Push for chaining");
});

// =============================================================================
// Presence Tests
// =============================================================================

test("Presence - initializes with channel", () => {
  const socket = new Socket("/ws", { transport: MockWebSocket });
  const channel = socket.channel("room:lobby");
  const presence = new Presence(channel);

  assertTrue(presence.channel === channel);
  assertEqual(presence.state, {});
});

test("Presence - syncState merges new state", () => {
  const state = {};
  const newState = {
    "user:1": { metas: [{ hb_ref: "1", name: "Alice" }] },
  };

  const result = Presence.syncState(state, newState);

  assertTrue("user:1" in result);
  assertEqual(result["user:1"].metas[0].name, "Alice");
});

test("Presence - syncState detects leaves", () => {
  const state = {
    "user:1": { metas: [{ hb_ref: "1", name: "Alice" }] },
    "user:2": { metas: [{ hb_ref: "2", name: "Bob" }] },
  };
  const newState = {
    "user:1": { metas: [{ hb_ref: "1", name: "Alice" }] },
  };

  let leftUser = null;
  const result = Presence.syncState(
    state,
    newState,
    () => {},
    (key) => {
      leftUser = key;
    }
  );

  assertEqual(leftUser, "user:2");
  assertFalse("user:2" in result);
});

test("Presence - syncDiff handles joins", () => {
  const state = {
    "user:1": { metas: [{ hb_ref: "1", name: "Alice" }] },
  };
  const diff = {
    joins: {
      "user:2": { metas: [{ hb_ref: "2", name: "Bob" }] },
    },
    leaves: {},
  };

  let joinedUser = null;
  const result = Presence.syncDiff(state, diff, (key) => {
    joinedUser = key;
  });

  assertEqual(joinedUser, "user:2");
  assertTrue("user:2" in result);
});

test("Presence - syncDiff handles leaves", () => {
  const state = {
    "user:1": { metas: [{ hb_ref: "1", name: "Alice" }] },
    "user:2": { metas: [{ hb_ref: "2", name: "Bob" }] },
  };
  const diff = {
    joins: {},
    leaves: {
      "user:2": { metas: [{ hb_ref: "2", name: "Bob" }] },
    },
  };

  let leftUser = null;
  const result = Presence.syncDiff(
    state,
    diff,
    () => {},
    (key) => {
      leftUser = key;
    }
  );

  assertEqual(leftUser, "user:2");
  assertFalse("user:2" in result);
});

test("Presence - list returns array of presences", () => {
  const state = {
    "user:1": { metas: [{ hb_ref: "1", name: "Alice" }] },
    "user:2": { metas: [{ hb_ref: "2", name: "Bob" }] },
  };

  const list = Presence.list(state);

  assertEqual(list.length, 2);
});

test("Presence - list with chooser transforms presences", () => {
  const state = {
    "user:1": { metas: [{ hb_ref: "1", name: "Alice" }] },
    "user:2": { metas: [{ hb_ref: "2", name: "Bob" }] },
  };

  const names = Presence.list(state, (key, { metas }) => metas[0].name);

  assertTrue(names.includes("Alice"));
  assertTrue(names.includes("Bob"));
});

test("Presence - clone creates deep copy", () => {
  const original = { a: { b: 1 } };
  const clone = Presence.clone(original);

  clone.a.b = 2;
  assertEqual(original.a.b, 1, "Original should not be modified");
});

// Run all tests
runTests();
