// SPDX-License-Identifier: MIT
//
// assets/bridge/dist/polyfills/events.js
//
// Minimal CJS EventEmitter. Used as a polyfill override via
// esbuild-plugins-node-modules-polyfill's `overrides` option, because
// @jspm/core/nodelibs/browser/events.js ships as an ES module whose
// `default` export is `{ EventEmitter, ... }` (an object, not the
// EventEmitter function itself). xml2js's Parser class extends
// require('events') directly via CoffeeScript-generated `extend(child, superClass)`,
// which assumes superClass IS the EventEmitter constructor — when it gets
// a plain object instead, inheritance silently breaks and methods like
// removeAllListeners disappear from Parser instances.
//
// This shim is a minimal EventEmitter focused on what the upstream NCM
// bundle actually calls: emit / on / once / off / addListener / removeListener
// / removeAllListeners / listeners / listenerCount / setMaxListeners.
// We don't need the full Node API; missing methods can be added if
// downstream code complains.
//
// Reference: events-browserify implementation, trimmed to the essentials.

'use strict';

class EventEmitter {
  constructor() {
    this._events = undefined;
    this._eventsCount = 0;
    this._maxListeners = undefined;
  }

  static init() {}
  static EventEmitter = EventEmitter;
  static defaultMaxListeners = 10;
  static listenerCount(emitter, type) {
    if (emitter.listenerCount) return emitter.listenerCount(type);
    return emitter.listeners(type).length;
  }

  setMaxListeners(n) { this._maxListeners = n; return this; }
  getMaxListeners() { return this._maxListeners ?? EventEmitter.defaultMaxListeners; }

  emit(type, ...args) {
    const events = this._events;
    if (!events || !events[type]) return false;
    const handler = events[type];
    if (typeof handler === 'function') {
      handler.apply(this, args);
    } else {
      for (let i = 0; i < handler.length; i++) handler[i].apply(this, args);
    }
    return true;
  }

  addListener(type, listener) { return this._add(type, listener, false); }
  on(type, listener) { return this._add(type, listener, false); }
  once(type, listener) {
    let fired = false;
    const wrap = (...args) => {
      this.removeListener(type, wrap);
      if (!fired) { fired = true; listener.apply(this, args); }
    };
    wrap.listener = listener;
    return this._add(type, wrap, false);
  }
  off(type, listener) { return this.removeListener(type, listener); }
  removeListener(type, listener) {
    const events = this._events;
    if (!events || !events[type]) return this;
    const list = events[type];
    if (list === listener || (list.listener && list.listener === listener)) {
      if (list.length) list.shift(); else delete events[type];
    } else if (typeof list !== 'function') {
      for (let i = list.length - 1; i >= 0; i--) {
        if (list[i] === listener || (list[i].listener && list[i].listener === listener)) {
          list.splice(i, 1);
          break;
        }
      }
      if (list.length === 0) delete events[type];
    }
    if (events[type] === undefined) this._eventsCount--;
    return this;
  }
  removeAllListeners(type) {
    const events = this._events;
    if (!events) return this;
    if (type === undefined) {
      this._events = {};
      this._eventsCount = 0;
    } else if (events[type]) {
      if (typeof events[type] === 'function') {
        delete events[type];
      } else {
        events[type].length = 0;
        delete events[type];
      }
      this._eventsCount--;
    }
    return this;
  }

  listeners(type) {
    const events = this._events;
    if (!events || !events[type]) return [];
    const list = events[type];
    if (typeof list === 'function') return [list];
    return list.slice();
  }

  listenerCount(type) {
    const events = this._events;
    if (!events || !events[type]) return 0;
    const list = events[type];
    if (typeof list === 'function') return 1;
    return list.length;
  }

  _add(type, listener, prepend) {
    const events = this._events ||= {};
    if (events.newListener) this.emit('newListener', type, listener);
    if (events[type]) {
      const list = events[type];
      if (typeof list === 'function') events[type] = prepend ? [listener, list] : [list, listener];
      else if (prepend) list.unshift(listener);
      else list.push(listener);
    } else {
      events[type] = listener;
    }
    this._eventsCount++;
    if (this.emit('newListener')) {} // no-op to silence linter
    return this;
  }
}

// CJS default export = the constructor itself (matches node's events module).
module.exports = EventEmitter;
module.exports.EventEmitter = EventEmitter;
module.exports.defaultMaxListeners = 10;
module.exports.usingDomains = false;
