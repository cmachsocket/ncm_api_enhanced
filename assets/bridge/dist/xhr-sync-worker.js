// Empty shim. jsdom only spawns this file for *synchronous* XHR, which the
// yidun Watchman SDK never uses (it's fully async). Safe no-op.
process.exit(0)