const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Get ERTS_INCLUDE_DIR from the env populated by :build_dot_zig
    const erts_include_dir = std.process.getEnvVarOwned(b.allocator, "ERTS_INCLUDE_DIR") catch blk: {
        // Fallback to extracting it from the erlang shell so it's possible to
        // execute zig build manually
        const argv = [_][]const u8{
            "erl",
            "-eval",
            "io:format(\"~s\", [lists:concat([code:root_dir(), \"/erts-\", erlang:system_info(version), \"/include\"])])",
            "-s",
            "init",
            "stop",
            "-noshell",
        };

        break :blk b.run(&argv);
    };

    const lib = b.addSharedLibrary(.{
        .name = "picosat_nif",
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib.addCSourceFiles(.{
        .files = &.{ "c_src/picosat.c", "c_src/picosat_nif.c" },
        // It seems picosat relies on some undefined behaviour, which means it crashes in the
        // default ReleaseSafe mode used by Zig due to UBSAN, so we disable it with -fno-sanitize=undefined
        // See also https://github.com/ziglang/zig/wiki/FAQ#why-do-i-get-illegal-instruction-when-using-with-zig-cc-to-build-c-code
        .flags = if (target.result.os.tag == .windows)
            &.{ "-std=c99", "-finline-functions", "-fno-sanitize=undefined", "-DNGETRUSAGE=1" }
        else
            &.{ "-std=c99", "-finline-functions", "-fno-sanitize=undefined" },
    });
    lib.addSystemIncludePath(.{ .cwd_relative = erts_include_dir });
    // This is needed to avoid errors on MacOS when loading the NIF
    lib.linker_allow_shlib_undefined = true;

    // Do this so `lib` doesn't get prepended to the lib name, and `.so` is used
    // as suffix also on MacOS, since it's required by the NIF loading mechanism.
    // See https://github.com/ziglang/zig/issues/2231
    // Windows still needs the .dll suffix
    const lib_name = if (target.result.os.tag == .windows) "picosat_nif.dll" else "picosat_nif.so";
    const nif_so_install = b.addInstallFileWithDir(lib.getEmittedBin(), .lib, lib_name);
    nif_so_install.step.dependOn(&lib.step);
    b.getInstallStep().dependOn(&nif_so_install.step);
}
