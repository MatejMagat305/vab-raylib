module main

import os
import vab.cli
import vab.vxt
import vab.util
import vab.android
import vab.android.util as androidutil
import vab.android.ndk


fn deploy(deploy_opt android.DeployOptions) {
	android.deploy(deploy_opt) or {
		util.vab_error('Deployment did not succeed', details: '${err}')
		if deploy_opt.kill_adb {
			cli.kill_adb()
		}
		exit(1)
	}
	deploy_opt.verbose(1, 'Deployed to ${deploy_opt.device_id} successfully')
	if deploy_opt.kill_adb {
		cli.kill_adb()
	}
}

pub struct VCompileOptions {
pub:
	verbosity int // level of verbosity
	cache     bool
	work_dir  string // temporary work directory
	input     string
	flags     []string // flags to pass to the v compiler
}

// uses_gc returns true if a `-gc` flag is found among the passed v flags.
pub fn (opt VCompileOptions) uses_gc() bool {
	mut uses_gc := true // V default
	for v_flag in opt.flags {
		if v_flag.starts_with('-gc') {
			if v_flag.ends_with('none') {
				uses_gc = false
			}
			break
		}
	}
	return uses_gc
}

pub struct VMetaInfo {
pub:
	imports []string
	c_flags []string
}

// v_dump_meta returns the information dumped by
// -dump-modules and -dump-c-flags.
pub fn v_dump_meta(opt VCompileOptions) !VMetaInfo {
	err_sig := @MOD + '.' + @FN
	os.mkdir_all(opt.work_dir) or {
		return error('${err_sig}: failed making directory "${opt.work_dir}". ${err}')
	}

	vexe := vxt.vexe()

	uses_gc := opt.uses_gc()

	// Dump modules and C flags to files
	v_cflags_file := os.join_path(opt.work_dir, 'v.cflags')
	os.rm(v_cflags_file) or {}
	v_dump_modules_file := os.join_path(opt.work_dir, 'v.modules')
	os.rm(v_dump_modules_file) or {}

	mut v_cmd := [
		vexe,
		'-os android',
	]
	if !uses_gc {
		v_cmd << '-gc none'
	}
	if !opt.cache {
		v_cmd << '-nocache'
	}
	v_cmd << opt.flags
	v_cmd << [
		'-cc clang',
		'-dump-modules "${v_dump_modules_file}"',
		'-dump-c-flags "${v_cflags_file}"',
	]
	v_cmd << opt.input

	// NOTE this command fails with a C compile error but the output we need is still
	// present... Yes - not exactly pretty.
	// VCROSS_COMPILER_NAME is needed (on at least Windows) - just get whatever compiler is available
	os.setenv('VCROSS_COMPILER_NAME', ndk.compiler_min_api(.c, ndk.default_version(),
		'arm64-v8a') or { '' }, true)

	verbosity_print_cmd(v_cmd, opt.verbosity)
	v_dump_res := run(v_cmd)
	if opt.verbosity > 3 {
		println(v_dump_res)
	}

	// Read in the dumped cflags
	cflags := os.read_file(v_cflags_file) or {
		flat_cmd := v_cmd.join(' ')
		return error('${err_sig}: failed reading C flags to "${v_cflags_file}". ${err}\nCompile output of `${flat_cmd}`:\n${v_dump_res}')
	}

	// Parse imported modules from dump
	mut imported_modules := os.read_file(v_dump_modules_file) or {
		flat_cmd := v_cmd.join(' ')
		return error('${err_sig}: failed reading module dump file "${v_dump_modules_file}". ${err}\nCompile output of `${flat_cmd}`:\n${v_dump_res}')
	}.split('\n').filter(it != '')
	imported_modules.sort()
	if opt.verbosity > 2 {
		println('Imported modules: ${imported_modules}')
	}

	return VMetaInfo{
		imports: imported_modules
		c_flags: cflags.split('\n')
	}
}

struct VImportCDeps {
pub:
	o_files map[string][]string
	a_files map[string][]string
}

// compile_v_imports_c_dependencies compiles the C dependencies of V's module imports.
pub fn compile_v_imports_c_dependencies(opt android.CompileOptions, imported_modules []string) !VImportCDeps {
	err_sig := @MOD + '.' + @FN

	mut o_files := map[string][]string{}
	mut a_files := map[string][]string{}

	uses_gc := opt.uses_gc()
	build_dir := opt.build_directory()!
	is_debug_build := opt.is_debug_build()

	// For all compilers
	mut cflags := opt.c_flags.clone()
	if opt.is_prod {
		cflags << ['-Os']
	} else {
		cflags << ['-O0']
	}
	cflags << ['-fPIC']
	cflags << ['-Wall', '-Wextra']

	mut android_includes := []string{}
	// Include NDK headers
	ndk_sysroot := ndk.sysroot_path(opt.ndk_version) or {
		return error('${err_sig}: getting NDK sysroot path.\n${err}')
	}
	android_includes << '-I"' + os.join_path(ndk_sysroot, 'usr', 'include') + '"'
	android_includes << '-I"' + os.join_path(ndk_sysroot, 'usr', 'include', 'android') + '"'

	v_thirdparty_dir := os.join_path(vxt.home(), 'thirdparty')

	archs := opt.archs()!

	mut jobs := []util.ShellJob{}
	for arch in archs {
		arch_o_dir := os.join_path(build_dir, 'o', arch)
		if !os.is_dir(arch_o_dir) {
			os.mkdir_all(arch_o_dir) or {
				return error('${err_sig}: failed making directory "${arch_o_dir}".\n${err}')
			}
		}

		compiler := ndk.compiler(.c, opt.ndk_version, arch, opt.api_level) or {
			return error('${err_sig}: failed getting NDK compiler.\n${err}')
		}

		if uses_gc {
			if opt.verbosity > 1 {
				println('Compiling libgc (${arch}) via -gc flag')
			}

			mut defines := []string{}
			if is_debug_build {
				defines << '-DGC_ASSERTIONS'
				defines << '-DGC_ANDROID_LOG'
			}
			defines << '-DGC_THREADS=1'
			defines << '-DGC_BUILTIN_ATOMIC=1'
			defines << '-D_REENTRANT'
			// NOTE it's currently a little unclear why this is needed.
			// V UI can crash and with when the gc is built into the exe and started *without* GC_INIT() the error would occur:
			defines << '-DUSE_MMAP' // Will otherwise crash with a message with a path to the lib in GC_unix_mmap_get_mem+528

			o_file := os.join_path(arch_o_dir, 'gc.o')
			build_cmd := [
				compiler,
				cflags.join(' '),
				'-I"' + os.join_path(v_thirdparty_dir, 'libgc', 'include') + '"',
				defines.join(' '),
				'-c "' + os.join_path(v_thirdparty_dir, 'libgc', 'gc.c') + '"',
				'-o "${o_file}"',
			]
			verbosity_print_cmd(build_cmd, opt.verbosity)
			o_res := androidutil.run_or_error(build_cmd)!
			if opt.verbosity > 2 {
				eprintln(o_res)
			}

			o_files[arch] << o_file

			jobs << util.ShellJob{
				cmd: build_cmd
			}
		}

		// stb_image via `stbi` module
		if 'stbi' in imported_modules {
			if opt.verbosity > 1 {
				println('Compiling stb_image (${arch}) via stbi module')
			}

			o_file := os.join_path(arch_o_dir, 'stbi.o')
			build_cmd := [
				compiler,
				cflags.join(' '),
				'-Wno-sign-compare',
				'-I"' + os.join_path(v_thirdparty_dir, 'stb_image') + '"',
				'-c "' + os.join_path(v_thirdparty_dir, 'stb_image', 'stbi.c') + '"',
				'-o "${o_file}"',
			]

			o_files[arch] << o_file

			jobs << util.ShellJob{
				cmd: build_cmd
			}
		}

		// cJson via `json` module
		if 'json' in imported_modules {
			if opt.verbosity > 1 {
				println('Compiling cJSON (${arch}) via json module')
			}
			o_file := os.join_path(arch_o_dir, 'cJSON.o')
			build_cmd := [
				compiler,
				cflags.join(' '),
				'-I"' + os.join_path(v_thirdparty_dir, 'cJSON') + '"',
				'-c "' + os.join_path(v_thirdparty_dir, 'cJSON', 'cJSON.c') + '"',
				'-o "${o_file}"',
			]

			o_files[arch] << o_file

			jobs << util.ShellJob{
				cmd: build_cmd
			}
		}
	}

	util.run_jobs(jobs, opt.parallel, opt.verbosity)!

	return VImportCDeps{
		o_files: o_files
		a_files: a_files
	}
}

// verbosity_print_cmd prints information about the `args` at certain `verbosity` levels.
fn verbosity_print_cmd(args []string, verbosity int) {
	if args.len > 0 && verbosity > 1 {
		cmd_short := args[0].all_after_last(os.path_separator)
		mut output := 'Running ${cmd_short} From: ${os.getwd()}'
		if verbosity > 2 {
			output += '\n' + args.join(' ')
		}
		println(output)
	}
}

fn run(args []string) os.Result {
	res := os.execute(args.join(' '))
	if res.exit_code < 0 {
		return os.Result{1, ''}
	}
	return res
}
