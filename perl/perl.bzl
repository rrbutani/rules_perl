# Copyright 2015 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Perl rules for Bazel"""

load("@bazel_skylib//lib:new_sets.bzl", "sets")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain")

PerlLibraryInfo = provider(
    doc = "A provider containing components of a `perl_library`",
    fields = [
        "transitive_perl_sources",
        "transitive_env_vars",
        "transitive_include_paths", # depset of runfiles-tree main-repo-dir relative include paths. i.e. like `short_path`s
    ],
)

# buildifier: disable=name-conventions
PerlLibrary = PerlLibraryInfo # to maintain backwards compatibility

PERL_XS_COPTS = [
    "-fwrapv",
    "-fPIC",
    "-fno-strict-aliasing",
    "-D_LARGEFILE_SOURCE",
    "-D_FILE_OFFSET_BITS=64",
]

_perl_file_types = [".pl", ".pm", ".t", ".so", ".ix", ".al", ""]
_perl_srcs_attr = attr.label_list(allow_files = _perl_file_types)

_perl_deps_attr = attr.label_list(
    allow_files = False,
    providers = [PerlLibraryInfo],
)

_perl_data_attr = attr.label_list(
    allow_files = True,
)

_perl_main_attr = attr.label(
    allow_single_file = _perl_file_types,
)

_perl_env_attr = attr.string_dict()

_perl_package_relative_includes_attr = attr.string_list(doc = (
    "include paths relative to the package this target is defined in\n\n" +
    "includes that do not cover any of the files in `srcs` produce errors\n" +
    "includes that escape the current repository or include the whole " +
    "repository produce an error"
))

_perl_add_include_for_repo_root = attr.bool(
    default = True,
    doc = (
        "adds a `-I<runfiles dir>/<defining repo's name>` include to " +
        "dependent `perl_binary`s, allowing you to `use` files from " +
        "`perl_library`s in this target's repo without needing to alter the " +
        "lib path"
    ),
)

def _get_main_from_sources(ctx):
    sources = ctx.files.srcs
    if len(sources) != 1:
        fail("Cannot infer main from multiple 'srcs'. Please specify 'main' attribute.", "main")
    return sources[0]

def _transitive_srcs(deps):
    return struct(
        srcs = [
            d[PerlLibraryInfo].transitive_perl_sources
            for d in deps
            if PerlLibraryInfo in d
        ],
        files = [
            d[DefaultInfo].default_runfiles.files
            for d in deps
        ],
    )

def transitive_deps(ctx, extra_files = [], extra_deps = [], extra_depsets = []):
    """Calculates transitive sets of args.

    Calculates the transitive sets for perl sources, data runfiles,
    include flags and runtime flags from the srcs, data and deps attributes
    in the context.

    Also adds extra_deps to the roots of the traversal.

    Args:
        ctx: a ctx object for a perl_library or a perl_binary rule.
        extra_files: a list of File objects to be added to the default_files
        extra_deps: a list of Target objects.
        extra_depsets: a list of depsets of File objects.
    """
    deps = _transitive_srcs(ctx.attr.deps + extra_deps)
    files = ctx.runfiles(
        files = extra_files + ctx.files.srcs + ctx.files.data,
        transitive_files = depset(transitive = deps.files + extra_depsets),
        collect_default = True,
    )
    return struct(
        srcs = depset(
            direct = ctx.files.srcs,
            transitive = deps.srcs,
        ),
        files = files,
    )

def transitive_env_vars(ctx):
    # TODO: apply make vars substitution to the values!
    new_vars = ctx.attr.env
    for name in new_vars.keys():
        if not _is_identifier(name):
            fail("%s is not a valid environment variable name." % str(name))

    # Would be nice to propagate as a depset but... can't do collision detection
    # eagerly then.
    #
    # TODO: probably just accept this and use the depset...
    other_vars = [
        source[PerlLibraryInfo].transitive_env_vars
        for source in ctx.attr.srcs + ctx.attr.data + ctx.attr.deps
        if PerlLibraryInfo in source
    ]
    vars = {}
    for var_dict in other_vars + [new_vars]:
        for k, v in var_dict.items():
            if k in vars and vars[k] != v:
                print("warning: overriding conflicting value for env var {}: prev = {}, new = {}".format(k, vars[k], v))
            vars[k] = v

    return vars

# The returned include paths are relative to the main-repo's dir under the
# runfiles tree for this target (just like `file.short_path`).
#
# See: https://bazel.build/extending/rules#runfiles_location
def _resolve_direct_includes(ctx):
    package_path = ctx.label.package
    target_repo = ctx.label.workspace_name

    include_paths = []
    for package_rel_inc in ctx.attr.package_relative_includes:
        repo_relative_inc = paths.normalize(paths.join(package_path, package_rel_inc))
        if paths.is_absolute(repo_relative_inc):
            fail("package relative includes must be relative, not absolute:", package_rel_inc)
        if repo_relative_inc == ".":
            fail("package relative includes cannot select the whole repository:", package_rel_inc)
        if repo_relative_inc == ".." or repo_relative_inc.startswith("../"):
            fail("package relative includes cannot escape the current repository:", package_rel_inc)

        covered = False
        for f in ctx.files.srcs:
            # don't consider files not in the target's repository:
            if f.owner.workspace_name != target_repo: continue

            # if this target isn't in the main repo, the short path will start
            # with `../<repo name>/`: remove this to get the repo-relative path:
            path_to_repo_dir = ""
            repo_relative_path = f.short_path
            if target_repo != "":
                path_to_repo_dir = "../" + target_repo + "/"
                if not repo_relative_path.startswith(path_to_repo_dir): fail("unreachable")
                repo_relative_path = repo_relative_path.removeprefix(path_to_repo_dir)

            # check if this file is beneath the include:
            if repo_relative_path.startswith(repo_relative_inc):
                include_paths.append(
                    paths.normalize(paths.join(path_to_repo_dir, repo_relative_inc))
                )

                covered = True
                break

        if not covered:
            fail("no files are covered by the package relative include:",
                package_rel_inc,
                "\nnormalized to repo:", repo_relative_inc,
                "got files:\n  -", "\n  - ".join([ str(f) for f in ctx.files.srcs])
            )


    if ctx.attr.add_include_for_repo_root:
        # If this target is in the main repo (i.e. `ctx.label.repo_name` is
        # empty), pwd (i.e. the runfiles tree's main-repo dir) is our include
        # path for the repo. Otherwise, it's: up a dir + the repo name.
        if not target_repo:
            inc = "./"
        else:
            inc = "../" + target_repo + "/"

        include_paths.append(inc)

    return include_paths

def transitive_includes(ctx):
    return depset(
        direct = _resolve_direct_includes(ctx),
        transitive = [
            d[PerlLibraryInfo].transitive_include_paths
            for d in ctx.attr.deps if PerlLibraryInfo in d
        ],
    )

def _perl_library_implementation(ctx, include_default_info = True):
    transitive_sources = transitive_deps(ctx)
    return ([] if not include_default_info else [
        DefaultInfo(
            runfiles = transitive_sources.files,
        ),
    ]) + [
        PerlLibraryInfo(
            transitive_perl_sources = transitive_sources.srcs,
            transitive_env_vars = transitive_env_vars(ctx),
            transitive_include_paths = transitive_includes(ctx)
        ),
    ]

def _perl_binary_implementation(ctx):
    toolchain = ctx.toolchains["@rules_perl//:toolchain_type"].perl_runtime
    interpreter = toolchain.interpreter

    transitive_sources = transitive_deps(ctx, extra_files = [ctx.outputs.executable], extra_depsets = [toolchain.runtime])

    include_paths = transitive_includes(ctx).to_list()

    main = ctx.file.main
    if main == None:
        main = _get_main_from_sources(ctx)

    ctx.actions.expand_template(
        template = ctx.file._wrapper_template,
        output = ctx.outputs.executable,
        substitutions = {
            "{env_vars}": _env_vars(ctx),
            "{interpreter}": interpreter.short_path,
            "{main}": main.short_path,

            # TODO: should we be hardcoding `_main` here for the workspace name?
            #
            # My understanding is that `.short_path` will return paths starting
            # with `../<repo>` for any file that's not in the main repo (not for
            # files not in the defining target's repo; i.e. for a target in an
            # external repo with a file in that same repo, `.short_path` will
            # return `../repo/<path>`, not `<path>`).
            #
            # In other words, I think this may break main-repo paths for targets
            # that are not in the main-repo...
            #
            # See: https://bazel.build/extending/rules#runfiles_location
            # "{workspace_name}": ctx.label.workspace_name or ctx.workspace_name,
            "{main_workspace_name}": ctx.workspace_name,
            "{shebang}": toolchain.binary_wrapper_shebang,

            "{includes}": "\n  ".join([
                # TODO: verify escape
                """"-I${{PATH_PREFIX}}"'{inc}'""".format(inc = i.replace("'", "\\'"))
                for i in include_paths
            ])
        },
        is_executable = True,
    )

    return [
        DefaultInfo(
            executable = ctx.outputs.executable,
            runfiles = transitive_sources.files,
        ),
    ] + _perl_library_implementation(ctx, include_default_info = False)

def _env_vars(ctx):
    environment = ""
    vars = transitive_env_vars(ctx)
    for name, value in vars.items():
        if not _is_identifier(name):
            fail("%s is not a valid environment variable name." % str(name))
        environment += ("{key}='{value}' ").format(
            key = name,
            value = value.replace("'", "\\'"),
        )
    return environment

def _is_identifier(name):
    # Must be non-empty.
    if name == None or len(name) == 0:
        return False

    # Must start with alpha or '_'
    if not (name[0].isalpha() or name[0] == "_"):
        return False

    # Must consist of alnum characters or '_'s.
    for c in name.elems():
        if not (c.isalnum() or c == "_"):
            return False
    return True

def _perl_test_implementation(ctx):
    return _perl_binary_implementation(ctx)

def _perl_xs_cc_lib(ctx, toolchain, srcs):
    cc_toolchain = find_cc_toolchain(ctx)
    xs_headers = toolchain.xs_headers

    includes = [f.dirname for f in xs_headers.to_list()]

    textual_hdrs = []
    for hdrs in ctx.attr.textual_hdrs:
        for hdr in hdrs.files.to_list():
            textual_hdrs.append(hdr)
            includes.append(hdr.dirname)

    includes = sets.make(includes)
    includes = sets.to_list(includes)

    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    (compilation_context, compilation_outputs) = cc_common.compile(
        actions = ctx.actions,
        name = ctx.label.name,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        srcs = srcs + ctx.files.cc_srcs,
        defines = ctx.attr.defines,
        additional_inputs = textual_hdrs,
        private_hdrs = xs_headers.to_list(),
        includes = includes,
        user_compile_flags = ctx.attr.copts + PERL_XS_COPTS,
        compilation_contexts = [],
    )

    (linking_context, _linking_outputs) = cc_common.create_linking_context_from_compilation_outputs(
        actions = ctx.actions,
        name = ctx.label.name,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        compilation_outputs = compilation_outputs,
        user_link_flags = ctx.attr.linkopts,
        linking_contexts = [],
    )

    return CcInfo(
        compilation_context = compilation_context,
        linking_context = linking_context,
    )

def _perl_xs_implementation(ctx):
    toolchain = ctx.toolchains["@rules_perl//:toolchain_type"].perl_runtime
    xsubpp = toolchain.xsubpp

    toolchain_files = toolchain.runtime

    gen = []
    cc_infos = []
    args_typemaps = []

    for typemap in ctx.files.typemaps:
        args_typemaps += ["-typemap", typemap.short_path]

    for src in ctx.files.srcs:
        out = ctx.actions.declare_file(paths.replace_extension(src.path, ".c"))

        ctx.actions.run(
            outputs = [out],
            inputs = [src] + ctx.files.typemaps,
            arguments = args_typemaps + ["-output", out.path, src.path],
            progress_message = "Translitterating %s to %s" % (src.short_path, out.short_path),
            executable = xsubpp,
            tools = toolchain_files,
        )

        gen.append(out)

    cc_info = _perl_xs_cc_lib(ctx, toolchain, gen)
    cc_infos = [cc_info] + [dep[CcInfo] for dep in ctx.attr.deps]
    cc_info = cc_common.merge_cc_infos(cc_infos = cc_infos)
    lib = cc_info.linking_context.linker_inputs.to_list()[0].libraries[0]
    dyn_lib = lib.dynamic_library

    if len(ctx.attr.output_loc):
        output = ctx.actions.declare_file(ctx.attr.output_loc)
    else:
        output = ctx.actions.declare_file(ctx.label.name + ".so")

    ctx.actions.run_shell(
        outputs = [output],
        inputs = [dyn_lib],
        arguments = [dyn_lib.path, output.path],
        command = "cp $1 $2",
    )

    return [
        cc_info,
        DefaultInfo(files = depset([output])),
    ]

perl_library = rule(
    attrs = {
        "data": _perl_data_attr,
        "deps": _perl_deps_attr,
        "srcs": _perl_srcs_attr,
        "env": _perl_env_attr,
        "package_relative_includes": _perl_package_relative_includes_attr,
        "add_include_for_repo_root": _perl_add_include_for_repo_root,
    },
    implementation = _perl_library_implementation,
    toolchains = ["@rules_perl//:toolchain_type"],
    provides = [PerlLibraryInfo],
)

perl_binary = rule(
    attrs = {
        "data": _perl_data_attr,
        "deps": _perl_deps_attr,
        "env": _perl_env_attr,
        "main": _perl_main_attr,
        "srcs": _perl_srcs_attr,
        "package_relative_includes": _perl_package_relative_includes_attr,
        "add_include_for_repo_root": _perl_add_include_for_repo_root,
        "_wrapper_template": attr.label(
            allow_single_file = True,
            default = "binary_wrapper.tpl",
        ),
    },
    executable = True,
    implementation = _perl_binary_implementation,
    toolchains = ["@rules_perl//:toolchain_type"],
    provides = [PerlLibraryInfo],
)

perl_test = rule(
    attrs = {
        "data": _perl_data_attr,
        "deps": _perl_deps_attr,
        "env": _perl_env_attr,
        "main": _perl_main_attr,
        "srcs": _perl_srcs_attr,
        "package_relative_includes": _perl_package_relative_includes_attr,
        "add_include_for_repo_root": _perl_add_include_for_repo_root,
        "_wrapper_template": attr.label(
            allow_single_file = True,
            default = "binary_wrapper.tpl",
        ),
    },
    executable = True,
    test = True,
    implementation = _perl_test_implementation,
    toolchains = ["@rules_perl//:toolchain_type"],
)

perl_xs = rule(
    attrs = {
        "cc_srcs": attr.label_list(allow_files = [".c", ".cc"]),
        "copts": attr.string_list(),
        "defines": attr.string_list(),
        "deps": attr.label_list(providers = [CcInfo]),
        "linkopts": attr.string_list(),
        "output_loc": attr.string(),
        "srcs": attr.label_list(allow_files = [".xs"]),
        "textual_hdrs": attr.label_list(allow_files = True),
        "typemaps": attr.label_list(allow_files = True),
        "_cc_toolchain": attr.label(default = Label("@bazel_tools//tools/cpp:current_cc_toolchain")),
    },
    implementation = _perl_xs_implementation,
    fragments = ["cpp"],
    toolchains = [
        "@rules_perl//:toolchain_type",
        "@bazel_tools//tools/cpp:toolchain_type",
    ],
)
