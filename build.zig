const std = @import("std");

pub fn build(b: *std.Build) void {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const decode_only = b.option(bool, "decode-only", "Export only decode-side WASM bindings") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "decode_only", decode_only);

    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm_module.addOptions("build_options", options);

    const wasm = b.addExecutable(.{
        .name = "tinypx",
        .root_module = wasm_module,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    b.installArtifact(wasm);
}
