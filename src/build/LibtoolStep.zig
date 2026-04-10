//! A zig builder step that merges multiple static libraries into a single
//! combined archive. Uses `zig ar` (LLVM archiver) instead of Apple's
//! `libtool -static` to avoid a macOS 26+ bug where libtool silently drops
//! archive members that aren't 8-byte aligned.
const LibtoolStep = @This();

const std = @import("std");
const Step = std.Build.Step;
const LazyPath = std.Build.LazyPath;

pub const Options = struct {
    /// The name of this step.
    name: []const u8,

    /// The filename (not the path) of the file to create. This will
    /// be placed in a unique hashed directory. Use out_path to access.
    out_name: []const u8,

    /// Library files (.a) to combine.
    sources: []LazyPath,
};

/// The step to depend on.
step: *Step,

/// The output file from the archive merge.
output: LazyPath,

pub fn create(b: *std.Build, opts: Options) *LibtoolStep {
    const self = b.allocator.create(LibtoolStep) catch @panic("OOM");

    const run_step = Step.Run.create(b, b.fmt("libtool {s}", .{opts.name}));
    run_step.addArgs(&.{ b.graph.zig_exe, "ar", "qcL" });
    const output = run_step.addOutputFileArg(opts.out_name);
    for (opts.sources) |source| run_step.addFileArg(source);

    self.* = .{
        .step = &run_step.step,
        .output = output,
    };

    return self;
}
