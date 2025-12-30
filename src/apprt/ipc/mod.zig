//! IPC server module for terminal automation.
//!
//! This module provides the server-side infrastructure for the socket-based
//! IPC protocol. Platform-specific apps (GTK, macOS) use this to handle
//! automation requests.

pub const server = @import("server.zig");

pub const Server = server.Server;
pub const Handler = server.Handler;

// Response helpers
pub const success = server.success;
pub const successData = server.successData;
pub const err = server.errorResponse;

// Re-export protocol types from socket client
const socket = @import("../socket.zig");
pub const Request = socket.Request;
pub const Response = socket.Response;
pub const getSocketPath = socket.getSocketPath;
pub const getSocketDir = socket.getSocketDir;
