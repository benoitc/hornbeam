/**
 * Hornbeam JavaScript Client TypeScript Definitions
 *
 * @license Apache-2.0
 * @copyright 2026 Benoit Chesneau
 */

export interface SocketOptions {
  /** Timeout in milliseconds for push operations (default: 10000) */
  timeout?: number;
  /** WebSocket transport constructor */
  transport?: typeof WebSocket;
  /** Heartbeat interval in milliseconds (default: 30000) */
  heartbeatIntervalMs?: number;
  /** Function returning reconnect delay based on retry count */
  reconnectAfterMs?: (tries: number) => number;
  /** Function returning rejoin delay based on retry count */
  rejoinAfterMs?: (tries: number) => number;
  /** Logger function */
  logger?: (kind: string, msg: string, data?: any) => void;
  /** Long poller timeout in milliseconds */
  longpollerTimeout?: number;
  /** Connection parameters to send with WebSocket URL */
  params?: Record<string, string>;
}

export interface ChannelParams {
  [key: string]: any;
}

export interface PushPayload {
  [key: string]: any;
}

export interface ReplyPayload {
  status: string;
  response: any;
}

export interface PresenceState {
  [key: string]: {
    metas: PresenceMeta[];
  };
}

export interface PresenceMeta {
  hb_ref: string;
  [key: string]: any;
}

export interface PresenceDiff {
  joins: PresenceState;
  leaves: PresenceState;
}

/**
 * Timer utility for reconnection and heartbeat scheduling
 */
export class Timer {
  constructor(callback: () => void, timerCalc: (tries: number) => number);
  reset(): void;
  scheduleTimeout(): void;
}

/**
 * Represents a message pushed to the server
 */
export class Push {
  constructor(
    channel: Channel,
    event: string,
    payload: PushPayload,
    timeout: number
  );

  /**
   * Resend the push with a new timeout
   */
  resend(timeout: number): void;

  /**
   * Send the push to the server
   */
  send(): void;

  /**
   * Register a callback for a specific response status
   */
  receive(status: string, callback: (response: any) => void): Push;
}

/**
 * Represents a connection to a specific topic
 */
export class Channel {
  /** Current channel state */
  readonly state: "closed" | "errored" | "joining" | "joined" | "leaving";
  /** Topic name */
  readonly topic: string;
  /** Parent socket */
  readonly socket: Socket;

  constructor(topic: string, params: ChannelParams, socket: Socket);

  /**
   * Join the channel
   * @param timeout Optional timeout in milliseconds
   */
  join(timeout?: number): Push;

  /**
   * Register a callback for channel close
   */
  onClose(callback: () => void): void;

  /**
   * Register a callback for channel error
   */
  onError(callback: (reason: any) => void): number;

  /**
   * Register a callback for a specific event
   * @returns Reference ID for the binding (use with off())
   */
  on(event: string, callback: (payload: any, ref?: string, joinRef?: string) => void): number;

  /**
   * Unregister event callbacks
   * @param event Event name
   * @param ref Optional specific binding reference to remove
   */
  off(event: string, ref?: number): void;

  /**
   * Push an event to the channel
   */
  push(event: string, payload?: PushPayload, timeout?: number): Push;

  /**
   * Leave the channel
   */
  leave(timeout?: number): Push;

  /**
   * Check if channel is closed
   */
  isClosed(): boolean;

  /**
   * Check if channel is errored
   */
  isErrored(): boolean;

  /**
   * Check if channel is joined
   */
  isJoined(): boolean;

  /**
   * Check if channel is joining
   */
  isJoining(): boolean;

  /**
   * Check if channel is leaving
   */
  isLeaving(): boolean;
}

/**
 * Distributed presence tracking
 */
export class Presence {
  /** Current presence state */
  readonly state: PresenceState;

  constructor(channel: Channel, opts?: {});

  /**
   * Register callback for when a presence joins
   */
  onJoin(callback: (key: string, currentPresence: PresenceState[string] | undefined, newPresence: PresenceState[string]) => void): void;

  /**
   * Register callback for when a presence leaves
   */
  onLeave(callback: (key: string, currentPresence: PresenceState[string], leftPresence: PresenceState[string]) => void): void;

  /**
   * Register callback for when presence list is synchronized
   */
  onSync(callback: () => void): void;

  /**
   * List all presences, optionally transformed by a chooser function
   */
  list<T = PresenceState[string]>(by?: (key: string, presence: PresenceState[string]) => T): T[];

  /**
   * Sync state with a new presence state
   */
  static syncState(
    currentState: PresenceState,
    newState: PresenceState,
    onJoin?: (key: string, currentPresence: PresenceState[string] | undefined, newPresence: PresenceState[string]) => void,
    onLeave?: (key: string, currentPresence: PresenceState[string], leftPresence: PresenceState[string]) => void
  ): PresenceState;

  /**
   * Sync state with a presence diff
   */
  static syncDiff(
    state: PresenceState,
    diff: PresenceDiff,
    onJoin?: (key: string, currentPresence: PresenceState[string] | undefined, newPresence: PresenceState[string]) => void,
    onLeave?: (key: string, currentPresence: PresenceState[string], leftPresence: PresenceState[string]) => void
  ): PresenceState;

  /**
   * List presences with optional transformation
   */
  static list<T = PresenceState[string]>(
    presences: PresenceState,
    chooser?: (key: string, presence: PresenceState[string]) => T
  ): T[];
}

/**
 * WebSocket connection manager
 */
export class Socket {
  /** Currently connected channels */
  readonly channels: Channel[];
  /** Configured timeout */
  readonly timeout: number;

  constructor(endPoint: string, opts?: SocketOptions);

  /**
   * Get the full endpoint URL with parameters
   */
  endPointURL(): string;

  /**
   * Disconnect from the server
   */
  disconnect(callback?: () => void, code?: number, reason?: string): void;

  /**
   * Connect to the server
   */
  connect(): void;

  /**
   * Log a message if logger is configured
   */
  log(kind: string, msg: string, data?: any): void;

  /**
   * Check if a logger is configured
   */
  hasLogger(): boolean;

  /**
   * Register callback for socket open
   */
  onOpen(callback: () => void): void;

  /**
   * Register callback for socket close
   */
  onClose(callback: (event: CloseEvent) => void): void;

  /**
   * Register callback for socket error
   */
  onError(callback: (error: Event) => void): void;

  /**
   * Register callback for all messages
   */
  onMessage(callback: (msg: [string | null, string, string, string, any]) => void): void;

  /**
   * Get current connection state
   */
  connectionState(): "connecting" | "open" | "closing" | "closed";

  /**
   * Check if socket is connected
   */
  isConnected(): boolean;

  /**
   * Create a new channel for a topic
   */
  channel(topic: string, chanParams?: ChannelParams): Channel;

  /**
   * Generate a unique message reference
   */
  makeRef(): string;
}
