# Copyright Google LLC All Rights Reserved.
#
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file at https://angular.io/license
"""Package Angular libraries for npm distribution

If all users of an Angular library use Bazel (e.g. internal usage in your company)
then you should simply add your library to the `deps` of the consuming application.

These rules exist for compatibility with non-Bazel consumers of your library.

It packages your library following the Angular Package Format, see the
specification of this format at https://goo.gl/jB3GVv
"""

load("@build_bazel_rules_nodejs//:providers.bzl", "DeclarationInfo", "JSEcmaScriptModuleInfo", "NpmPackageInfo", "node_modules_aspect")
load("@build_bazel_rules_nodejs//internal/linker:link_node_modules.bzl", "LinkerPackageMappingInfo")
load(
    "@build_bazel_rules_nodejs//internal/pkg_npm:pkg_npm.bzl",
    "PKG_NPM_ATTRS",
    "PKG_NPM_OUTPUTS",
    "create_package",
)
load("@rules_nodejs//nodejs:providers.bzl", "StampSettingInfo")
load("//packages/bazel/src:external.bzl", "FLAT_DTS_FILE_SUFFIX")
load("//packages/bazel/src/ng_module:partial_compilation.bzl", "partial_compilation_transition")

# Prints a debug message if "--define=VERBOSE_LOGS=true" is specified.
def _debug(vars, *args):
    if "VERBOSE_LOGS" in vars.keys():
        print("[ng_package.bzl]", args)

_DEFAULT_NG_PACKAGER = "//@angular/bazel/bin:packager"
_DEFAULT_ROLLUP_CONFIG_TMPL = "//:node_modules/@angular/bazel/src/ng_package/rollup.config.js"
_DEFAULT_ROLLUP = "//@angular/bazel/src/ng_package:rollup_for_ng_package"

_NG_PACKAGE_MODULE_MAPPINGS_ATTR = "ng_package_module_mappings"

def _ng_package_module_mappings_aspect_impl(target, ctx):
    mappings = dict()
    for dep in ctx.rule.attr.deps:
        if hasattr(dep, _NG_PACKAGE_MODULE_MAPPINGS_ATTR):
            for k, v in getattr(dep, _NG_PACKAGE_MODULE_MAPPINGS_ATTR).items():
                if k in mappings and mappings[k] != v:
                    fail(("duplicate module mapping at %s: %s maps to both %s and %s" %
                          (target.label, k, mappings[k], v)), "deps")
                mappings[k] = v
    if ((hasattr(ctx.rule.attr, "module_name") and ctx.rule.attr.module_name) or
        (hasattr(ctx.rule.attr, "module_root") and ctx.rule.attr.module_root)):
        mn = ctx.rule.attr.module_name
        if not mn:
            mn = target.label.name
        mr = target.label.package
        if target.label.workspace_root:
            mr = "%s/%s" % (target.label.workspace_root, mr)
        if ctx.rule.attr.module_root and ctx.rule.attr.module_root != ".":
            if ctx.rule.attr.module_root.endswith(".ts"):
                # This is the type-checking module mapping. Strip the trailing .d.ts
                # as it doesn't belong in TypeScript's path mapping.
                mr = "%s/%s" % (mr, ctx.rule.attr.module_root.replace(".d.ts", ""))
            else:
                mr = "%s/%s" % (mr, ctx.rule.attr.module_root)
        if mn in mappings and mappings[mn] != mr:
            fail(("duplicate module mapping at %s: %s maps to both %s and %s" %
                  (target.label, mn, mappings[mn], mr)), "deps")
        mappings[mn] = mr
    return struct(ng_package_module_mappings = mappings)

ng_package_module_mappings_aspect = aspect(
    _ng_package_module_mappings_aspect_impl,
    attr_aspects = ["deps"],
)

WELL_KNOWN_EXTERNALS = [
    "@angular/animations",
    "@angular/animations/browser",
    "@angular/animations/browser/testing",
    "@angular/common",
    "@angular/common/http",
    "@angular/common/http/testing",
    "@angular/common/testing",
    "@angular/common/upgrade",
    "@angular/compiler",
    "@angular/compiler/testing",
    "@angular/core",
    "@angular/core/testing",
    "@angular/elements",
    "@angular/forms",
    "@angular/localize",
    "@angular/localize/init",
    "@angular/platform-browser",
    "@angular/platform-browser/animations",
    "@angular/platform-browser/testing",
    "@angular/platform-browser-dynamic",
    "@angular/platform-browser-dynamic/testing",
    "@angular/platform-server",
    "@angular/platform-server/init",
    "@angular/platform-server/testing",
    "@angular/router",
    "@angular/router/testing",
    "@angular/router/upgrade",
    "@angular/service-worker",
    "@angular/service-worker/config",
    "@angular/upgrade",
    "@angular/upgrade/static",
    "rxjs",
    "rxjs/operators",
    "tslib",
]

def _compute_node_modules_root(ctx):
    """Computes the node_modules root from the node_modules and deps attributes.

    Args:
      ctx: the skylark execution context

    Returns:
      The node_modules root as a string
    """
    node_modules_root = None
    for d in ctx.attr.deps:
        if NpmPackageInfo in d:
            possible_root = "/".join(["external", d[NpmPackageInfo].workspace, "node_modules"])
            if not node_modules_root:
                node_modules_root = possible_root
            elif node_modules_root != possible_root:
                fail("All npm dependencies need to come from a single workspace. Found '%s' and '%s'." % (node_modules_root, possible_root))
    if not node_modules_root:
        # there are no fine grained deps but we still need a node_modules_root even if its empty
        node_modules_root = "external/npm/node_modules"
    return node_modules_root

def _write_rollup_config(
        ctx,
        root_dir,
        filename = "_%s.rollup.conf.js",
        downlevel_to_es2015 = False):
    """Generate a rollup config file.

    Args:
      ctx: Bazel rule execution context
      root_dir: root directory for module resolution (defaults to None)
      filename: output filename pattern (defaults to `_%s.rollup.conf.js`)

    Returns:
      The rollup config file. See https://rollupjs.org/guide/en#configuration-files
    """
    config = ctx.actions.declare_file(filename % ctx.label.name)

    mappings = dict()
    all_deps = ctx.attr.deps + ctx.attr.srcs
    for dep in all_deps:
        if hasattr(dep, _NG_PACKAGE_MODULE_MAPPINGS_ATTR):
            for k, v in getattr(dep, _NG_PACKAGE_MODULE_MAPPINGS_ATTR).items():
                if k in mappings and mappings[k] != v:
                    fail(("duplicate module mapping at %s: %s maps to both %s and %s" %
                          (dep.label, k, mappings[k], v)), "deps")
                mappings[k] = v

    externals = WELL_KNOWN_EXTERNALS + ctx.attr.externals

    # Whether the --stamp flag is applied in the context of the action's execution.
    stamp = ctx.attr.stamp[StampSettingInfo].value

    # Pass external & globals through a templated config file because on Windows there is
    # an argument limit and we there might be a lot of globals which need to be passed to
    # rollup.

    ctx.actions.expand_template(
        output = config,
        template = ctx.file.rollup_config_tmpl,
        substitutions = {
            "TMPL_banner_file": "\"%s\"" % ctx.file.license_banner.path if ctx.file.license_banner else "undefined",
            "TMPL_module_mappings": str(mappings),
            "TMPL_node_modules_root": _compute_node_modules_root(ctx),
            "TMPL_root_dir": root_dir,
            "TMPL_stamp_data": "\"%s\"" % ctx.version_file.path if (stamp and ctx.version_file) else "undefined",
            "TMPL_workspace_name": ctx.workspace_name,
            "TMPL_external": ", ".join(["'%s'" % e for e in externals]),
            "TMPL_downlevel_to_es2015": "true" if downlevel_to_es2015 else "false",
        },
    )

    return config

def _run_rollup(ctx, bundle_name, rollup_config, entry_point, inputs, js_output, format):
    map_output = ctx.actions.declare_file(js_output.basename + ".map", sibling = js_output)

    args = ctx.actions.args()
    args.add("--input", entry_point.path)
    args.add("--config", rollup_config)
    args.add("--output.file", js_output)
    args.add("--output.format", format)

    # After updating to build_bazel_rules_nodejs 0.27.0+, rollup has been updated to v1.3.1
    # which tree shakes @__PURE__ annotations and const variables which are later amended by NGCC.
    # We turn this feature off for ng_package as Angular bundles contain these and there are
    # test failures if they are removed.
    # See comments in:
    # https://github.com/angular/angular/pull/29210
    # https://github.com/angular/angular/pull/32069
    args.add("--no-treeshake")

    # Note: if the input has external source maps then we need to also install and use
    #   `rollup-plugin-sourcemaps`, which will require us to use rollup.config.js file instead
    #   of command line args
    args.add("--sourcemap")

    args.add("--preserveSymlinks")

    # We will produce errors as needed. Anything else is spammy: a well-behaved
    # bazel rule prints nothing on success.
    args.add("--silent")

    # Whether the --stamp flag is applied in the context of the action's execution.
    stamp = ctx.attr.stamp[StampSettingInfo].value

    other_inputs = [rollup_config]
    if ctx.file.license_banner:
        other_inputs.append(ctx.file.license_banner)
    if stamp and ctx.version_file:
        other_inputs.append(ctx.version_file)
    ctx.actions.run(
        progress_message = "ng_package: Rollup %s %s" % (bundle_name, ctx.label),
        mnemonic = "AngularPackageRollup",
        inputs = inputs.to_list() + other_inputs,
        outputs = [js_output, map_output],
        executable = ctx.executable.rollup,
        tools = [ctx.executable.rollup],
        arguments = [args],
    )
    return [js_output, map_output]

# Serializes a file into a struct that matches the `BazelFileInfo` type in the
# packager implementation. Useful for transmission of such information.
def _serialize_file(file):
    return struct(path = file.path, shortPath = file.short_path)

# Serializes a list of files into a JSON string that can be passed as CLI argument
# for the packager, matching the `BazelFileInfo[]` type in the packager implementation.
def _serialize_files_for_arg(files):
    result = []
    for file in files:
        result.append(_serialize_file(file))
    return json.encode(result)

def _filter_js_inputs(all_inputs):
    return [f for f in all_inputs if f.path.endswith(".js") or f.path.endswith(".json")]

def _find_matching_file(files, search_short_path):
    for file in files:
        if file.short_path == search_short_path:
            return file
    fail("Could not find file that is expected to exist: %s" % search_short_path)

def _is_part_of_package(file, owning_package):
    return file.short_path.startswith(owning_package)

def _filter_esm_files_to_include(files, owning_package):
    result = []

    for file in files:
        # We skip all `.externs.js` files as those should not be shipped as part of
        # the ESM2020 output. The externs are empty because `ngc-wrapped` disables
        # externs generation in prodmode for workspaces other than `google3`.
        if file.path.endswith("externs.js"):
            continue

        # We omit all non-JavaScript files. These are not required for the FESM bundle
        # generation and are not expected to be put into the `esm2020` output.
        if not file.path.endswith(".js") and not file.path.endswith(".mjs"):
            continue

        if _is_part_of_package(file, owning_package):
            result.append(file)

    return result

def _filter_typings_to_include(files, owning_package):
    return [f for f in files if _is_part_of_package(f, owning_package)]

# ng_package produces package that is npm-ready.
def _ng_package_impl(ctx):
    npm_package_directory = ctx.actions.declare_directory("%s.ng_pkg" % ctx.label.name)
    owning_package = ctx.label.package

    # The name of the primary entry-point FESM bundles. If not explicitly provided through
    # the entry-point name attribute, we compute the name from the owning package
    # e.g. if defined in `packages/core:npm_package`, the name is resolved to be `core`.
    primary_bundle_name = \
        ctx.attr.primary_bundle_name if ctx.attr.primary_bundle_name else owning_package.split("/")[-1]

    # Disallow generated files in the "srcs" attribute.
    for src in ctx.files.srcs:
        if not src.is_source:
            fail("Unexpected generated files in the `srcs` attribute of `ng_package`.")

    # These accumulators match the directory names where the files live in the
    # Angular package format.
    fesm2020 = []
    fesm2015 = []
    bundled_type_definitions = []

    # We collect all ESM2020 source
    unscoped_esm2020_depsets = []
    unscoped_type_definition_depsets = []

    # We infer the entry points to be:
    # - ng_module rules in the deps (they have an "angular" provider)
    # - in this package or a subpackage
    # - those that have a module_name attribute (they produce flat module metadata)
    collected_entry_points = []

    # Name of the NPM package. The name is computed as we iterate through all
    # dependencies of the `ng_package`.
    npm_package_name = None

    for dep in ctx.attr.deps:
        if not dep.label.package.startswith(owning_package):
            fail("Unexpected dependency. %s is defined outside of %s." % (dep, owning_package))

        # Collect ESM2020 source files from the dependency, including transitive sources which
        # are not directly defined in the entry-point. This is necessary to allow for
        # entry-points to rely on sub-targets (which can be done for incrementality).
        if JSEcmaScriptModuleInfo in dep:
            unscoped_esm2020_depsets.append(dep[JSEcmaScriptModuleInfo].sources)

        # Collect the type definitions files for the entry-point.
        if hasattr(dep, "dts_bundle"):
            bundled_type_definitions.append(dep.dts_bundle)
        elif DeclarationInfo in dep:
            unscoped_type_definition_depsets.append(dep[DeclarationInfo].transitive_declarations)

        if len(unscoped_type_definition_depsets) > 0 and len(bundled_type_definitions) > 0:
            # bundle_dts needs to be enabled/disabled for all entry points.
            fail("Expected all or none of the entry points to have 'bundle_dts' enabled.")

    # Note: Using `to_list()` is expensive but we cannot get around this here as
    # we need to filter out generated files and need to be able to iterate through
    # JavaScript and typing files in order to detect entry-point index and typing files.
    unscoped_esm2020 = depset(transitive = unscoped_esm2020_depsets).to_list()
    unscoped_type_definitions = depset(transitive = unscoped_type_definition_depsets).to_list()

    for dep in ctx.attr.deps:
        # Module name of the current entry-point. eg. @angular/core/testing
        module_name = ""

        # Packsge name where this entry-point is defined in,
        entry_point_package = dep.label.package

        # Intentionally evaluates to empty string for the main entry point
        entry_point = entry_point_package[len(owning_package) + 1:]

        # Whether this dependency is for the primary entry-point of the package.
        is_primary_entry_point = entry_point == ""

        # Extract the "module_name" from either "ts_library" or "ng_module". Both
        # set the "module_name" in the provider struct.
        if hasattr(dep, "module_name"):
            module_name = dep.module_name

        if is_primary_entry_point:
            npm_package_name = module_name

        if hasattr(dep, "angular") and hasattr(dep.angular, "flat_module_metadata"):
            # For dependencies which are built using the "ng_module" with flat module bundles
            # enabled, we determine the module name, the flat module index file, the metadata
            # file and the typings entry point from the flat module metadata which is set by
            # the "ng_module" rule.
            ng_module_metadata = dep.angular.flat_module_metadata
            module_name = ng_module_metadata.module_name
            es2020_entry_point = ng_module_metadata.flat_module_out_prodmode_file
            typings_file = ng_module_metadata.typings_file
            guessed_paths = False

            _debug(
                ctx.var,
                "entry-point %s is built using a flat module bundle." % dep,
                "using %s as main file of the entry-point" % es2020_entry_point,
            )
        else:
            _debug(
                ctx.var,
                "entry-point %s does not have flat module metadata." % dep,
                "guessing `index.mjs` as main file of the entry-point",
            )

            # In case the dependency is built through the "ts_library" rule, or the "ng_module"
            # rule does not generate a flat module bundle, we determine the index file and
            # typings entry-point through the most reasonable defaults (i.e. "package/index").
            es2020_entry_point = _find_matching_file(unscoped_esm2020, "%s/index.mjs" % entry_point_package)
            typings_file = _find_matching_file(unscoped_type_definitions, "%s/index.d.ts" % entry_point_package)
            guessed_paths = True

        bundle_name = "%s.mjs" % (primary_bundle_name if is_primary_entry_point else entry_point)
        fesm2020_file = ctx.actions.declare_file("fesm2020/%s" % bundle_name)
        fesm2015_file = ctx.actions.declare_file("fesm2015/%s" % bundle_name)

        # Store the collected entry point in a list of all entry-points. This
        # can be later passed to the packager as a manifest.
        collected_entry_points.append(struct(
            module_name = module_name,
            es2020_entry_point = es2020_entry_point,
            fesm2020_file = fesm2020_file,
            fesm2015_file = fesm2015_file,
            typings_file = typings_file,
            guessed_paths = guessed_paths,
        ))

        # Also include files from npm fine grained deps as inputs.
        # These deps are identified by the NpmPackageInfo provider.
        node_modules_files = []
        for dep in ctx.attr.deps:
            if NpmPackageInfo in dep:
                # Note: `to_list` is expensive but we want to filter out non-JS files
                # as these would result in a larger set of runfiles.
                node_modules_files += _filter_js_inputs(dep.files.to_list())

        # Note: For creating the bundles, we use all the ESM2020 sources that have been
        # collected from the dependencies. This allows for bundling of code that is not
        # necessarily part of the owning package (using the `externals` attribute)
        rollup_inputs = depset(node_modules_files + unscoped_esm2020)
        esm2020_config = _write_rollup_config(ctx, ctx.bin_dir.path, filename = "_%s.rollup_esm2020.conf.js")
        esm2015_config = _write_rollup_config(ctx, ctx.bin_dir.path, filename = "_%s.rollup_esm2015.conf.js", downlevel_to_es2015 = True)

        fesm2020.extend(
            _run_rollup(
                ctx,
                "fesm2020",
                esm2020_config,
                es2020_entry_point,
                rollup_inputs,
                fesm2020_file,
                format = "esm",
            ),
        )

        fesm2015.extend(
            _run_rollup(
                ctx,
                "fesm2015",
                esm2015_config,
                es2020_entry_point,
                rollup_inputs,
                fesm2015_file,
                format = "esm",
            ),
        )

    # Filter ESM2020 JavaScript and type declaration files to files which are part of the
    # owning package. The packager should not copy external files into the package.
    esm2020 = _filter_esm_files_to_include(unscoped_esm2020, owning_package)
    type_definitions = _filter_typings_to_include(unscoped_type_definitions, owning_package)

    packager_inputs = (
        ctx.files.srcs +
        ctx.files.data +
        type_definitions +
        bundled_type_definitions +
        fesm2020 + esm2020 + fesm2015
    )

    packager_args = ctx.actions.args()
    packager_args.use_param_file("%s", use_always = True)

    # The order of arguments matters here, as they are read in order in packager.ts.
    packager_args.add(npm_package_directory.path)
    packager_args.add(ctx.label.package)

    # Marshal the metadata into a JSON string so we can parse the data structure
    # in the TypeScript program easily.
    metadata_arg = {}
    for m in collected_entry_points:
        # The captured properties need to match the `EntryPointInfo` interface
        # in the packager executable tool.
        metadata_arg[m.module_name] = {
            "index": _serialize_file(m.es2020_entry_point),
            "fesm2020Bundle": _serialize_file(m.fesm2020_file),
            "fesm2015Bundle": _serialize_file(m.fesm2015_file),
            "typings": _serialize_file(m.typings_file),
            # If the paths for that entry-point were guessed (e.g. "ts_library" rule or
            # "ng_module" without flat module bundle), we pass this information to the packager.
            "guessedPaths": m.guessed_paths,
        }

    # Encodes the package metadata with all its entry-points into JSON so that
    # it can be deserialized by the packager tool. The struct needs to match with
    # the `PackageMetadata` interface in the packager tool.
    packager_args.add(json.encode(struct(
        npmPackageName = npm_package_name,
        entryPoints = metadata_arg,
    )))

    if ctx.file.readme_md:
        packager_inputs.append(ctx.file.readme_md)
        packager_args.add(ctx.file.readme_md.path)
    else:
        # placeholder
        packager_args.add("")

    packager_args.add(_serialize_files_for_arg(fesm2020))
    packager_args.add(_serialize_files_for_arg(esm2020))
    packager_args.add(_serialize_files_for_arg(fesm2015))
    packager_args.add(_serialize_files_for_arg(ctx.files.srcs))
    packager_args.add(_serialize_files_for_arg(type_definitions))

    # TODO: figure out a better way to gather runfiles providers from the transitive closure.
    packager_args.add(_serialize_files_for_arg(ctx.files.data))

    if ctx.file.license_banner:
        packager_inputs.append(ctx.file.license_banner)
        packager_args.add(ctx.file.license_banner)
    else:
        # placeholder
        packager_args.add("")

    packager_args.add(_serialize_files_for_arg(bundled_type_definitions))
    packager_args.add(FLAT_DTS_FILE_SUFFIX)

    ctx.actions.run(
        progress_message = "Angular Packaging: building npm package %s" % str(ctx.label),
        mnemonic = "AngularPackage",
        inputs = packager_inputs,
        outputs = [npm_package_directory],
        executable = ctx.executable.ng_packager,
        arguments = [packager_args],
    )

    # Re-use the create_package function from the nodejs npm_package rule.
    package_dir = create_package(
        ctx,
        [],
        [npm_package_directory] + ctx.files.nested_packages,
    )

    # Empty depset. Since these are immutable we don't need to multiple new instances.
    empty_depset = depset([])

    return [
        DefaultInfo(files = depset([package_dir])),
        # We disable propagation of the `link_node_modules` aspect. We do not want
        # mappings from dependencies for the `ng_package` to leak to consumers relying
        # on the NPM package target. Since we use an outgoing transition for dependencies
        # the mapping paths would be different for the dependency targets and cause mapping
        # conflicts if tests rely on both a `ng_package` and a transitive dep target of it.
        # More details: https://github.com/bazelbuild/rules_nodejs/issues/2941.
        # TODO(devversion): Consider supporting the `package_name` attribute.
        LinkerPackageMappingInfo(mappings = empty_depset, node_modules_roots = empty_depset),
    ]

_NG_PACKAGE_DEPS_ASPECTS = [ng_package_module_mappings_aspect, node_modules_aspect]

_NG_PACKAGE_ATTRS = dict(PKG_NPM_ATTRS, **{
    "srcs": attr.label_list(
        doc = """JavaScript source files from the workspace.
        These can use ES2020 syntax and ES Modules (import/export)""",
        allow_files = True,
    ),
    "externals": attr.string_list(
        doc = """List of external module that should not be bundled into the flat ESM bundles.""",
        default = [],
    ),
    "license_banner": attr.label(
        doc = """A .txt file passed to the `banner` config option of rollup.
        The contents of the file will be copied to the top of the resulting bundles.
        Note that you can replace a version placeholder in the license file, by using
        the special version `0.0.0-PLACEHOLDER`. See the section on stamping in the README.""",
        allow_single_file = [".txt"],
    ),
    "deps": attr.label_list(
        doc = """Other rules that produce JavaScript outputs, such as `ts_library`.""",
        aspects = _NG_PACKAGE_DEPS_ASPECTS,
        cfg = partial_compilation_transition,
    ),
    "data": attr.label_list(
        doc = "Additional, non-Angular files to be added to the package, e.g. global CSS assets.",
        allow_files = True,
        cfg = partial_compilation_transition,
    ),
    "readme_md": attr.label(allow_single_file = [".md"]),
    "primary_bundle_name": attr.string(
        doc = "Name to use when generating bundle files for the primary entry-point.",
    ),
    "ng_packager": attr.label(
        default = Label(_DEFAULT_NG_PACKAGER),
        executable = True,
        cfg = "host",
    ),
    "rollup": attr.label(
        default = Label(_DEFAULT_ROLLUP),
        executable = True,
        cfg = "host",
    ),
    "rollup_config_tmpl": attr.label(
        default = Label(_DEFAULT_ROLLUP_CONFIG_TMPL),
        allow_single_file = True,
    ),
    # Needed in order to allow for the outgoing transition on the `deps` attribute.
    # https://docs.bazel.build/versions/main/skylark/config.html#user-defined-transitions.
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
})

def _ng_package_outputs(name):
    """This function computes the named outputs for an ng_package rule."""
    outputs = {}
    for key in PKG_NPM_OUTPUTS:
        # PKG_NPM_OUTPUTS is a "normal" dict-valued outputs so it looks like
        #  "pack": "%{name}.pack",
        # But this is a function-valued outputs.
        # Bazel won't replace the %{name} token so we have to do it.
        outputs[key] = PKG_NPM_OUTPUTS[key].replace("%{name}", name)
    return outputs

ng_package = rule(
    implementation = _ng_package_impl,
    attrs = _NG_PACKAGE_ATTRS,
    outputs = _ng_package_outputs,
    toolchains = ["@rules_nodejs//nodejs:toolchain_type"],
)
"""
ng_package produces an npm-ready package from an Angular library.
"""

def ng_package_macro(name, **kwargs):
    ng_package(
        name = name,
        **kwargs
    )
    native.alias(
        name = name + ".pack",
        actual = select({
            "@bazel_tools//src/conditions:host_windows": name + ".pack.bat",
            "//conditions:default": name + ".pack.sh",
        }),
    )
    native.alias(
        name = name + ".publish",
        actual = select({
            "@bazel_tools//src/conditions:host_windows": name + ".publish.bat",
            "//conditions:default": name + ".publish.sh",
        }),
    )
