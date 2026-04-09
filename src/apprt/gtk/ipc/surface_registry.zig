const std = @import("std");

var mutex: std.Thread.Mutex = .{};
var surfaces: std.AutoHashMapUnmanaged(usize, *anyopaque) = .empty;

pub fn register(surface: *anyopaque) !void {
    mutex.lock();
    defer mutex.unlock();
    try surfaces.put(std.heap.c_allocator, @intFromPtr(surface), surface);
}

pub fn unregister(surface: *anyopaque) void {
    mutex.lock();
    defer mutex.unlock();
    _ = surfaces.remove(@intFromPtr(surface));
}

pub fn get(id: usize) ?*anyopaque {
    mutex.lock();
    defer mutex.unlock();
    return surfaces.get(id);
}
