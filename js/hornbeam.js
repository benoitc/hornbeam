/**
 * Hornbeam JavaScript Client
 *
 * Channels and presence for Hornbeam applications.
 *
 * @license Apache-2.0
 * @copyright 2026 Benoit Chesneau
 */

/**
 * Timer utility for reconnection and heartbeat
 */
class Timer {
  constructor(callback, timerCalc) {
    this.callback = callback;
    this.timerCalc = timerCalc;
    this.timer = null;
    this.tries = 0;
  }

  reset() {
    this.tries = 0;
    clearTimeout(this.timer);
  }

  scheduleTimeout() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.tries = this.tries + 1;
      this.callback();
    }, this.timerCalc(this.tries + 1));
  }
}

/**
 * Push - represents a message pushed to the server
 */
class Push {
  constructor(channel, event, payload, timeout) {
    this.channel = channel;
    this.event = event;
    this.payload = payload || {};
    this.timeout = timeout;
    this.receivedResp = null;
    this.recHooks = [];
    this.sent = false;
    this.ref = null;
    this.refEvent = null;
    this.timeoutTimer = null;
  }

  resend(timeout) {
    this.timeout = timeout;
    this.reset();
    this.send();
  }

  send() {
    if (this.hasReceived("timeout")) {
      return;
    }
    this.startTimeout();
    this.sent = true;
    this.channel.socket.push({
      topic: this.channel.topic,
      event: this.event,
      payload: this.payload,
      ref: this.ref,
      join_ref: this.channel.joinRef()
    });
  }

  receive(status, callback) {
    if (this.hasReceived(status)) {
      callback(this.receivedResp.response);
    }
    this.recHooks.push({ status, callback });
    return this;
  }

  reset() {
    this.cancelRefEvent();
    this.ref = null;
    this.refEvent = null;
    this.receivedResp = null;
    this.sent = false;
  }

  matchReceive({ status, response }) {
    this.recHooks
      .filter((h) => h.status === status)
      .forEach((h) => h.callback(response));
  }

  cancelRefEvent() {
    if (!this.refEvent) {
      return;
    }
    this.channel.off(this.refEvent);
  }

  cancelTimeout() {
    clearTimeout(this.timeoutTimer);
    this.timeoutTimer = null;
  }

  startTimeout() {
    if (this.timeoutTimer) {
      this.cancelTimeout();
    }
    this.ref = this.channel.socket.makeRef();
    this.refEvent = this.channel.replyEventName(this.ref);

    this.channel.on(this.refEvent, (payload) => {
      this.cancelRefEvent();
      this.cancelTimeout();
      this.receivedResp = payload;
      this.matchReceive(payload);
    });

    this.timeoutTimer = setTimeout(() => {
      this.trigger("timeout", {});
    }, this.timeout);
  }

  hasReceived(status) {
    return this.receivedResp && this.receivedResp.status === status;
  }

  trigger(status, response) {
    this.channel.trigger(this.refEvent, { status, response });
  }
}

/**
 * Channel - represents a connection to a specific topic
 */
class Channel {
  constructor(topic, params, socket) {
    this.state = "closed";
    this.topic = topic;
    this.params = params || {};
    this.socket = socket;
    this.bindings = [];
    this.bindingRef = 0;
    this.timeout = socket.timeout;
    this.joinedOnce = false;
    this.joinPush = new Push(this, "hb_join", this.params, this.timeout);
    this.pushBuffer = [];
    this.rejoinTimer = new Timer(
      () => {
        if (this.socket.isConnected()) {
          this.rejoin();
        }
      },
      socket.rejoinAfterMs
    );

    this.joinPush.receive("ok", () => {
      this.state = "joined";
      this.rejoinTimer.reset();
      this.pushBuffer.forEach((p) => p.send());
      this.pushBuffer = [];
    });

    this.joinPush.receive("error", () => {
      this.state = "errored";
      if (this.socket.isConnected()) {
        this.rejoinTimer.scheduleTimeout();
      }
    });

    this.onClose(() => {
      this.rejoinTimer.reset();
      if (this.socket.hasLogger()) {
        this.socket.log("channel", `close ${this.topic} ${this.joinRef()}`);
      }
      this.state = "closed";
      this.socket.remove(this);
    });

    this.onError((reason) => {
      if (this.socket.hasLogger()) {
        this.socket.log("channel", `error ${this.topic}`, reason);
      }
      if (this.isJoining()) {
        this.joinPush.reset();
      }
      this.state = "errored";
      if (this.socket.isConnected()) {
        this.rejoinTimer.scheduleTimeout();
      }
    });

    this.on("hb_reply", (payload, ref) => {
      this.trigger(this.replyEventName(ref), payload);
    });
  }

  join(timeout) {
    if (this.joinedOnce) {
      throw new Error(
        "tried to join multiple times. 'join' can only be called once per channel instance"
      );
    }
    this.timeout = timeout || this.timeout;
    this.joinedOnce = true;
    this.rejoin();
    return this.joinPush;
  }

  onClose(callback) {
    this.on("hb_close", callback);
  }

  onError(callback) {
    return this.on("hb_error", (reason) => callback(reason));
  }

  on(event, callback) {
    const ref = this.bindingRef++;
    this.bindings.push({ event, ref, callback });
    return ref;
  }

  off(event, ref) {
    this.bindings = this.bindings.filter((bind) => {
      return !(
        bind.event === event &&
        (typeof ref === "undefined" || ref === bind.ref)
      );
    });
  }

  push(event, payload, timeout) {
    if (!this.joinedOnce) {
      throw new Error(
        `tried to push '${event}' to '${this.topic}' before joining. Use channel.join() before pushing events`
      );
    }
    const pushEvent = new Push(
      this,
      event,
      payload,
      timeout || this.timeout
    );
    if (this.canPush()) {
      pushEvent.send();
    } else {
      pushEvent.startTimeout();
      this.pushBuffer.push(pushEvent);
    }

    return pushEvent;
  }

  leave(timeout) {
    this.rejoinTimer.reset();
    this.joinPush.cancelTimeout();

    this.state = "leaving";
    const onClose = () => {
      if (this.socket.hasLogger()) {
        this.socket.log("channel", `leave ${this.topic}`);
      }
      this.trigger("hb_close", "leave");
    };

    const leavePush = new Push(this, "hb_leave", {}, timeout || this.timeout);
    leavePush.receive("ok", () => onClose()).receive("timeout", () => onClose());
    leavePush.send();

    if (!this.canPush()) {
      leavePush.trigger("ok", {});
    }

    return leavePush;
  }

  onMessage(_event, payload, _ref) {
    return payload;
  }

  isMember(topic, event, payload, joinRef) {
    if (this.topic !== topic) {
      return false;
    }

    if (
      joinRef &&
      joinRef !== this.joinRef() &&
      ["hb_reply", "hb_error"].includes(event)
    ) {
      return false;
    }

    return true;
  }

  joinRef() {
    return this.joinPush.ref;
  }

  rejoin(timeout) {
    if (this.isLeaving()) {
      return;
    }
    this.socket.leaveOpenTopic(this.topic);
    this.state = "joining";
    this.joinPush.resend(timeout || this.timeout);
  }

  trigger(event, payload, ref, joinRef) {
    const handledPayload = this.onMessage(event, payload, ref, joinRef);
    if (payload && !handledPayload) {
      throw new Error(
        "channel onMessage callbacks must return the payload, modified or unmodified"
      );
    }

    this.bindings
      .filter((bind) => bind.event === event)
      .map((bind) => bind.callback(handledPayload, ref, joinRef || this.joinRef()));
  }

  replyEventName(ref) {
    return `chan_reply_${ref}`;
  }

  isClosed() {
    return this.state === "closed";
  }

  isErrored() {
    return this.state === "errored";
  }

  isJoined() {
    return this.state === "joined";
  }

  isJoining() {
    return this.state === "joining";
  }

  isLeaving() {
    return this.state === "leaving";
  }

  canPush() {
    return this.socket.isConnected() && this.isJoined();
  }
}

/**
 * Presence - distributed presence tracking
 */
class Presence {
  constructor(channel, opts = {}) {
    this.state = {};
    this.pendingDiffs = [];
    this.channel = channel;
    this.joinRef = null;
    this.caller = {
      onJoin: function () {},
      onLeave: function () {},
      onSync: function () {}
    };

    channel.on("presence_state", (state) => {
      const { onJoin, onLeave, onSync } = this.caller;

      this.joinRef = channel.joinRef();
      this.state = Presence.syncState(this.state, state, onJoin, onLeave);

      this.pendingDiffs.forEach((diff) => {
        this.state = Presence.syncDiff(this.state, diff, onJoin, onLeave);
      });
      this.pendingDiffs = [];
      onSync();
    });

    channel.on("presence_diff", (diff) => {
      const { onJoin, onLeave, onSync } = this.caller;

      if (this.inPendingSyncState()) {
        this.pendingDiffs.push(diff);
      } else {
        this.state = Presence.syncDiff(this.state, diff, onJoin, onLeave);
        onSync();
      }
    });
  }

  onJoin(callback) {
    this.caller.onJoin = callback;
  }

  onLeave(callback) {
    this.caller.onLeave = callback;
  }

  onSync(callback) {
    this.caller.onSync = callback;
  }

  list(by) {
    return Presence.list(this.state, by);
  }

  inPendingSyncState() {
    return !this.joinRef || this.joinRef !== this.channel.joinRef();
  }

  // Static methods for presence state management

  static syncState(currentState, newState, onJoin, onLeave) {
    const state = this.clone(currentState);
    const joins = {};
    const leaves = {};

    this.map(state, (key, presence) => {
      if (!newState[key]) {
        leaves[key] = presence;
      }
    });

    this.map(newState, (key, newPresence) => {
      const currentPresence = state[key];
      if (currentPresence) {
        const newRefs = newPresence.metas.map((m) => m.hb_ref);
        const curRefs = currentPresence.metas.map((m) => m.hb_ref);
        const joinedMetas = newPresence.metas.filter(
          (m) => curRefs.indexOf(m.hb_ref) < 0
        );
        const leftMetas = currentPresence.metas.filter(
          (m) => newRefs.indexOf(m.hb_ref) < 0
        );
        if (joinedMetas.length > 0) {
          joins[key] = newPresence;
          joins[key].metas = joinedMetas;
        }
        if (leftMetas.length > 0) {
          leaves[key] = this.clone(currentPresence);
          leaves[key].metas = leftMetas;
        }
      } else {
        joins[key] = newPresence;
      }
    });

    return this.syncDiff(state, { joins, leaves }, onJoin, onLeave);
  }

  static syncDiff(state, diff, onJoin, onLeave) {
    const { joins, leaves } = this.clone(diff);
    state = this.clone(state);

    this.map(joins, (key, newPresence) => {
      const currentPresence = state[key];
      state[key] = this.clone(newPresence);
      if (currentPresence) {
        const joinedRefs = state[key].metas.map((m) => m.hb_ref);
        const curMetas = currentPresence.metas.filter(
          (m) => joinedRefs.indexOf(m.hb_ref) < 0
        );
        state[key].metas.unshift(...curMetas);
      }
      if (onJoin) {
        onJoin(key, currentPresence, newPresence);
      }
    });

    this.map(leaves, (key, leftPresence) => {
      const currentPresence = state[key];
      if (!currentPresence) {
        return;
      }
      const refsToRemove = leftPresence.metas.map((m) => m.hb_ref);
      currentPresence.metas = currentPresence.metas.filter(
        (p) => refsToRemove.indexOf(p.hb_ref) < 0
      );
      if (onLeave) {
        onLeave(key, currentPresence, leftPresence);
      }
      if (currentPresence.metas.length === 0) {
        delete state[key];
      }
    });

    return state;
  }

  static list(presences, chooser) {
    chooser = chooser || ((key, pres) => pres);

    return this.map(presences, (key, presence) => {
      return chooser(key, presence);
    });
  }

  static map(obj, func) {
    return Object.keys(obj).map((key) => func(key, obj[key]));
  }

  static clone(obj) {
    return JSON.parse(JSON.stringify(obj));
  }
}

/**
 * Socket connection states
 */
const SOCKET_STATES = {
  connecting: 0,
  open: 1,
  closing: 2,
  closed: 3
};

/**
 * Default options
 */
const DEFAULT_TIMEOUT = 10000;
const DEFAULT_HEARTBEAT_INTERVAL = 30000;
const WS_CLOSE_NORMAL = 1000;

/**
 * Socket - WebSocket connection manager
 */
class Socket {
  constructor(endPoint, opts = {}) {
    this.stateChangeCallbacks = {
      open: [],
      close: [],
      error: [],
      message: []
    };
    this.channels = [];
    this.sendBuffer = [];
    this.ref = 0;
    this.timeout = opts.timeout || DEFAULT_TIMEOUT;
    this.transport = opts.transport || WebSocket;
    this.heartbeatIntervalMs = opts.heartbeatIntervalMs || DEFAULT_HEARTBEAT_INTERVAL;
    this.reconnectAfterMs =
      opts.reconnectAfterMs ||
      function (tries) {
        return [1000, 2000, 5000, 10000][tries - 1] || 10000;
      };
    this.rejoinAfterMs =
      opts.rejoinAfterMs ||
      function (tries) {
        return [1000, 2000, 5000, 10000][tries - 1] || 10000;
      };
    this.logger = opts.logger || null;
    this.longpollerTimeout = opts.longpollerTimeout || 20000;
    this.params = opts.params || {};
    this.endPoint = `${endPoint}/${this._transport()}`;
    this.heartbeatTimer = null;
    this.pendingHeartbeatRef = null;
    this.reconnectTimer = new Timer(() => {
      this.teardown(() => this.connect());
    }, this.reconnectAfterMs);
    this.conn = null;
  }

  _transport() {
    return "websocket";
  }

  endPointURL() {
    return this._appendParams(this.endPoint, this.params);
  }

  _appendParams(url, params) {
    if (Object.keys(params).length === 0) {
      return url;
    }
    const prefix = url.match(/\?/) ? "&" : "?";
    const query = new URLSearchParams(params).toString();
    return `${url}${prefix}${query}`;
  }

  disconnect(callback, code, reason) {
    this.reconnectTimer.reset();
    this.teardown(callback, code, reason);
  }

  connect() {
    if (this.conn) {
      return;
    }

    this.conn = new this.transport(this.endPointURL());
    this.conn.binaryType = "arraybuffer";
    this.conn.onopen = () => this._onConnOpen();
    this.conn.onerror = (error) => this._onConnError(error);
    this.conn.onmessage = (event) => this._onConnMessage(event);
    this.conn.onclose = (event) => this._onConnClose(event);
  }

  log(kind, msg, data) {
    if (this.logger) {
      this.logger(kind, msg, data);
    }
  }

  hasLogger() {
    return this.logger !== null;
  }

  onOpen(callback) {
    this.stateChangeCallbacks.open.push(callback);
  }

  onClose(callback) {
    this.stateChangeCallbacks.close.push(callback);
  }

  onError(callback) {
    this.stateChangeCallbacks.error.push(callback);
  }

  onMessage(callback) {
    this.stateChangeCallbacks.message.push(callback);
  }

  _onConnOpen() {
    if (this.hasLogger()) {
      this.log("transport", `connected to ${this.endPointURL()}`);
    }
    this._flushSendBuffer();
    this.reconnectTimer.reset();
    this._resetHeartbeat();
    this.stateChangeCallbacks.open.forEach((callback) => callback());
  }

  _onConnClose(event) {
    if (this.hasLogger()) {
      this.log("transport", "close", event);
    }
    this._triggerChanError();
    clearInterval(this.heartbeatTimer);
    if (event.code !== WS_CLOSE_NORMAL) {
      this.reconnectTimer.scheduleTimeout();
    }
    this.stateChangeCallbacks.close.forEach((callback) => callback(event));
  }

  _onConnError(error) {
    if (this.hasLogger()) {
      this.log("transport", "error", error);
    }
    this._triggerChanError();
    this.stateChangeCallbacks.error.forEach((callback) => callback(error));
  }

  _triggerChanError() {
    this.channels.forEach((channel) => {
      if (!channel.isErrored() && !channel.isLeaving() && !channel.isClosed()) {
        channel.trigger("hb_error");
      }
    });
  }

  connectionState() {
    switch (this.conn && this.conn.readyState) {
      case SOCKET_STATES.connecting:
        return "connecting";
      case SOCKET_STATES.open:
        return "open";
      case SOCKET_STATES.closing:
        return "closing";
      default:
        return "closed";
    }
  }

  isConnected() {
    return this.connectionState() === "open";
  }

  remove(channel) {
    this.channels = this.channels.filter(
      (c) => c.joinRef() !== channel.joinRef()
    );
  }

  channel(topic, chanParams = {}) {
    const chan = new Channel(topic, chanParams, this);
    this.channels.push(chan);
    return chan;
  }

  push(data) {
    const { topic, event, payload, ref, join_ref } = data;
    const callback = () => {
      const msg = JSON.stringify([join_ref, ref, topic, event, payload]);
      this.conn.send(msg);
    };
    if (this.hasLogger()) {
      this.log("push", `${topic} ${event} (${join_ref}, ${ref})`, payload);
    }
    if (this.isConnected()) {
      callback();
    } else {
      this.sendBuffer.push(callback);
    }
  }

  makeRef() {
    const newRef = this.ref + 1;
    if (newRef === this.ref) {
      this.ref = 0;
    } else {
      this.ref = newRef;
    }
    return this.ref.toString();
  }

  leaveOpenTopic(topic) {
    const dupChannel = this.channels.find(
      (c) => c.topic === topic && (c.isJoined() || c.isJoining())
    );
    if (dupChannel) {
      if (this.hasLogger()) {
        this.log("transport", `leaving duplicate topic "${topic}"`);
      }
      dupChannel.leave();
    }
  }

  _onConnMessage(rawMessage) {
    const msg = JSON.parse(rawMessage.data);
    const [join_ref, ref, topic, event, payload] = msg;

    if (ref && ref === this.pendingHeartbeatRef) {
      this.pendingHeartbeatRef = null;
    }

    if (this.hasLogger()) {
      this.log(
        "receive",
        `${payload.status || ""} ${topic} ${event} ${(ref && "(" + ref + ")") || ""}`,
        payload
      );
    }

    this.channels
      .filter((channel) => channel.isMember(topic, event, payload, join_ref))
      .forEach((channel) => channel.trigger(event, payload, ref, join_ref));

    this.stateChangeCallbacks.message.forEach((callback) =>
      callback(msg)
    );
  }

  _flushSendBuffer() {
    if (this.isConnected() && this.sendBuffer.length > 0) {
      this.sendBuffer.forEach((callback) => callback());
      this.sendBuffer = [];
    }
  }

  teardown(callback, code, reason) {
    if (this.conn) {
      this.conn.onclose = function () {}; // noop
      if (code) {
        this.conn.close(code, reason || "");
      } else {
        this.conn.close();
      }
      this.conn = null;
    }
    callback && callback();
  }

  _resetHeartbeat() {
    this.pendingHeartbeatRef = null;
    clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = setInterval(
      () => this._sendHeartbeat(),
      this.heartbeatIntervalMs
    );
  }

  _sendHeartbeat() {
    if (!this.isConnected()) {
      return;
    }
    if (this.pendingHeartbeatRef) {
      this.pendingHeartbeatRef = null;
      if (this.hasLogger()) {
        this.log(
          "transport",
          "heartbeat timeout. Attempting to re-establish connection"
        );
      }
      this.conn.close(WS_CLOSE_NORMAL, "heartbeat timeout");
      return;
    }
    this.pendingHeartbeatRef = this.makeRef();
    this.push({
      topic: "hornbeam",
      event: "heartbeat",
      payload: {},
      ref: this.pendingHeartbeatRef
    });
  }
}

// Export for various module systems
if (typeof module !== "undefined" && module.exports) {
  module.exports = { Socket, Channel, Push, Presence, Timer };
}

if (typeof window !== "undefined") {
  window.Hornbeam = { Socket, Channel, Push, Presence, Timer };
}

// ES6 export - only works with bundlers or type="module"
// export { Socket, Channel, Push, Presence, Timer };
