module main

import os
// NOTE: This should never depend on `sdl` since the system <-> module version mismatch bug is not yet 100% solved.
// Compiling and running this should never yield a SDL compilation error, so:
// import sdl // NO-NO
import flag
import semver
import net.http
import vab.cli
import vab.vxt
import vab.util
import vab.paths
import vab.android.util as vabutil
import vab.android
import vab.android.ndk
import vab.util as job_util
	
const default_package_id = 'io.v.android.raylib'
const default_activity_name = 'VRaylibActivity'

const default_vab_sdl_options = cli.Options{
	lib_name:      'main'
	package_id:    default_package_id
	activity_name: default_activity_name
	// Raylib's Android Java skeleton uses mipmaps
	icon_mipmaps: true
	// Set defaults for vab-raylib
	default_package_id:    default_package_id
	default_activity_name: default_activity_name
}

const exe_version = version()
const exe_name = os.file_name(os.executable())
const exe_short_name = os.file_name(os.executable()).replace('.exe', '')
const exe_dir = os.dir(os.real_path(os.executable()))
const exe_description = '${exe_short_name}
compile SDL for Android.
'
const exe_git_hash = ab_commit_hash()
const accepted_input_files = ['.v', '.apk', '.aab']

	
// main is a rough reimplementation of `vab`'s main function
fn main() {
	mut args := arguments()

	// NOTE: do not support running sub commands
	// cli.run_vab_sub_command(args)

	// Get input to `vab`.
	mut input := ''
	input, args = cli.input_from_args(args)

	// Collect user flags precedented going from most implicit to most explicit.
	// Start with defaults -> overwrite by .vab file entries -> overwrite by VAB_FLAGS -> overwrite by commandline flags.
	mut opt := cli.Options{
		...default_vab_sdl_options
	}

	opt = cli.options_from_dot_vab(input, opt) or {
		util.vab_error('Could not parse `.vab`', details: '${err}')
		exit(1)
	}

	opt = cli.options_from_env(opt) or {
		util.vab_error('Could not parse `VAB_FLAGS`', details: '${err}')
		util.vab_notice('Use `${cli.exe_short_name} -h` to see all flags')
		exit(1)
	}

	mut unmatched_args := []string{}
	opt, unmatched_args = cli.options_from_arguments(args, opt) or {
		util.vab_error('Could not parse `os.args`', details: '${err}')
		util.vab_notice('Use `${cli.exe_short_name} -h` to see all flags')
		exit(1)
	}

	if unmatched_args.len > 0 {
		util.vab_error('Could not parse arguments', details: 'No matches for ${unmatched_args}')
		util.vab_notice('Use `${cli.exe_short_name} -h` to see all flags')
		exit(1)
	}

	if opt.dump_usage {
		documentation := flag.to_doc[cli.Options](cli.vab_documentation_config) or {
			util.vab_error('Could not generate usage documentation via `flag.to_doc[cli.Options](...)` this should not happen',
				details: '${err}'
			)
			exit(1)
		}
		println(documentation)
		exit(0)
	}

	// Call the doctor at this point
	if opt.run_builtin_cmd == 'doctor' {
		// Validate environment
		cli.check_essentials(false)
		opt.resolve(false)
		cli.doctor(opt)
		sdl_doctor(sdl_opt) // Add this extra command's output at the bottom
		exit(0)
	}

	// Validate environment
	cli.check_essentials(true)
	opt.resolve(true)

	cli.validate_input(input) or {
		util.vab_error('${cli.exe_short_name}: ${err}')
		exit(1)
	}
	opt.input = input

	opt.resolve_output()

	// Validate environment after options and input has been resolved
	opt.validate_env()

	opt.ensure_launch_fields()

	// Keystore file
	keystore := opt.resolve_keystore() or {
		util.vab_error('Could not resolve keystore', details: '${err}')
		exit(1)
	}

	ado := opt.as_android_deploy_options() or {
		util.vab_error('Could not create deploy options', details: '${err}')
		exit(1)
	}
	deploy_opt := android.DeployOptions{
		...ado
		keystore: keystore
	}

	opt.verbose(2, 'Output will be signed with keystore at "${deploy_opt.keystore.path}"')

	screenshot_opt := opt.as_android_screenshot_options(deploy_opt)

	input_ext := os.file_ext(opt.input)

	// Early deployment of existing packages.
	if input_ext in ['.apk', '.aab'] {
		if deploy_opt.device_id != '' {
			deploy(deploy_opt)
			android.screenshot(screenshot_opt) or {
				util.vab_error('Screenshot did not succeed', details: '${err}')
				exit(1)
			}
			exit(0)
		}
	}
	//===========================================
	// raylib
	aco := opt.as_android_compile_options()
	comp_opt := android.CompileOptions{
	 	...aco
	 	cache_key: if os.is_dir(input) || input_ext == '.v' { opt.input } else { '' }
	 }
	 compile_raylib(comp_opt) or {
	 	util.vab_error('Compiling did not succeed', details: '${err}')
	 	exit(1)
	 }
	// =================================

	apo := opt.as_android_package_options()
	pck_opt := android.PackageOptions{
		...apo
		keystore:   keystore
		base_files: base_files_path // NOTE: these are implicitly picked up by `vab` relative to the executable, this project uses a dynamic approach. See also: default_base_files_path in vab sources
		// prepare_base_fn:
	}
	android.package(pck_opt) or {
		util.vab_error('Packaging did not succeed', details: '${err}')
		cli.doctor_remedy(pck_opt, err.msg()) // Suggest possible fixes to known errors
		exit(1)
	}

	if deploy_opt.device_id != '' {
		deploy(deploy_opt)
		android.screenshot(screenshot_opt) or {
			util.vab_error('Screenshot did not succeed', details: '${err}')
			exit(1)
		}
	} else {
		if opt.verbosity > 0 {
			opt.verbose(1, 'Generated ${os.real_path(opt.output)}')
			util.vab_notice('Use `${cli.exe_short_name} --device <id> ${os.real_path(opt.output)}` to deploy package')
			util.vab_notice('Use `${cli.exe_short_name} --device <id> run ${os.real_path(opt.output)}` to both deploy and run the package')
			if deploy_opt.run != '' {
				util.vab_notice('Use `adb -s "<DEVICE ID>" shell am start -n "${deploy_opt.run}"` to run the app on the device, via adb')
			}
		}
	}
}

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


fn build_raylib(opt CompileOptions, raylib_path string, arch string) ! {
	build_path := os.join_path(raylib_path, 'build')
	// check if the library already exists or compile it
	if os.exists(os.join_path(build_path, arch, 'libraylib.a')) {
		return
	} else {
		src_path := os.join_path(raylib_path, 'src')
		ndk_path := ndk.root()
		os.execute('make -C ${src_path} clean')
		arch_name := if arch == 'arm64-v8a' {
			'arm64'
		} else if arch == 'armeabi-v7a' {
			'arm'
		} else if arch in ['x86', 'x86_64'] {
			arch
		} else {
			''
		}
		if arch_name !in ['arm64', 'arm', 'x86', 'x86_64'] {
			return error('${arch_name} is now a known architecture')
		}
		os.execute('make -C ${src_path} PLATFORM=PLATFORM_ANDROID ANDROID_NDK=${ndk_path} ANDROID_ARCH=${arch_name} ANDROID_API_VERSION=${opt.api_level} ')
		taget_path := os.join_path(build_path, arch)
		os.mkdir_all(taget_path) or { return error('failed making directory "${taget_path}"') }
		os.mv(os.join_path(src_path, 'libraylib.a'), taget_path) or {
			return error('failed to move .a file from ${src_path} to ${taget_path}')
		}
	}
}

fn download_raylib(raylib_path string) {
	// clone raylib from github
	os.execute('git clone https://github.com/raysan5/raylib.git -o ${raylib_path}')
}

pub fn compile_raylib(opt CompileOptions) ! {
	err_sig := @MOD + '.' + @FN
	os.mkdir_all(opt.work_dir) or {
		return error('${err_sig}: failed making directory "${opt.work_dir}". ${err}')
	}
	build_dir := opt.build_directory()!

	v_meta_dump := compile_v_to_c(opt) or {
		return IError(CompileError{
			kind: .v_to_c
			err: err.msg()
		})
	}

	is_raylib := 'raylib' in v_meta_dump.imports

	// check if raylib floder is found else clone it
	if is_raylib {
		return error('THIS vab extension need build raylib, package raylib is mising.....')
	}
	raylib_path := os.join_path(vxt.vmodules() or {
		return error('${err_sig}:vmodules folder not found')
	}, 'raylib', 'raylib')
	if os.exists(raylib_path) {
		for arch in opt.archs {
			build_raylib(opt, raylib_path, arch) or {
				return error('cant build raylib ERROR: ${err}')
			}
		}
	} else {
		download_raylib(raylib_path)
		for arch in opt.archs {
			build_raylib(opt, raylib_path, arch) or {
				return error('cant build raylib ERROR: ${err}')
			}
		}
	}


	v_cflags := v_meta_dump.c_flags
	imported_modules := v_meta_dump.imports

	v_output_file := os.join_path(opt.work_dir, 'v_android.c')
	v_thirdparty_dir := os.join_path(vxt.home(), 'thirdparty')

	uses_gc := opt.uses_gc()

	// Poor man's cache check
	mut hash := ''
	hash_file := os.join_path(opt.work_dir, 'v_android.hash')
	if opt.cache && os.exists(build_dir) && os.exists(v_output_file) {
		mut bytes := os.read_bytes(v_output_file) or {
			return error('${err_sig}: failed reading "${v_output_file}".\n${err}')
		}
		bytes << '${opt.str()}-${opt.cache_key}'.bytes()
		hash = md5.sum(bytes).hex()

		if os.exists(hash_file) {
			prev_hash := os.read_file(hash_file) or { '' }
			if hash == prev_hash {
				if opt.verbosity > 1 {
					println('Skipping compile. Hashes match ${hash}')
				}
				return
			}
		}
	}

	if hash != '' && os.exists(v_output_file) {
		if opt.verbosity > 2 {
			println('Writing new hash ${hash}')
		}
		os.rm(hash_file) or {}
		mut hash_fh := os.open_file(hash_file, 'w+', 0o700) or {
			return error('${err_sig}: failed opening "${hash_file}". ${err}')
		}
		hash_fh.write(hash.bytes()) or {
			return error('${err_sig}: failed writing to "${hash_file}".\n${err}')
		}
		hash_fh.close()
	}

	// Remove any previous builds
	if os.is_dir(build_dir) {
		os.rmdir_all(build_dir) or {
			return error('${err_sig}: failed removing "${build_dir}": ${err}')
		}
	}
	os.mkdir(build_dir) or {
		return error('${err_sig}: failed making directory "${build_dir}".\n${err}')
	}

	archs := opt.archs()!

	if opt.verbosity > 0 {
		println('Compiling V import C dependencies (.c to .o for ${archs})' +
			if opt.parallel { ' in parallel' } else { '' })
	}

	vicd := compile_v_imports_c_dependencies(opt, imported_modules) or {
		return IError(CompileError{
			kind: .c_to_o
			err: err.msg()
		})
	}
	mut o_files := vicd.o_files.clone()
	mut a_files := vicd.a_files.clone()

	// For all compilers
	mut cflags := opt.c_flags.clone()
	mut includes := []string{}
	mut defines := []string{}
	mut ldflags := []string{}

	// Grab any external C flags
	for line in v_cflags {
		if line.contains('.tmp.c') || line.ends_with('.o"') {
			continue
		}
		if line.starts_with('-D') {
			defines << line
		}
		if line.starts_with('-I') {
			if line.contains('/usr/') {
				continue
			}
			includes << line
		}
		if line.starts_with('-l') {
			if line.contains('-lgc') {
				// compiled in
				continue
			}
			if line.contains('-lpthread') {
				// pthread is built into bionic
				continue
			}
			ldflags << line
		}
	}

	// ... still a bit of a mess
	if opt.is_prod {
		cflags << ['-Os']
	} else {
		cflags << ['-O0']
	}
	cflags << ['-fPIC', '-fvisibility=hidden', '-ffunction-sections', '-fdata-sections',
		'-ferror-limit=1']

	cflags << ['-Wall', '-Wextra']

	cflags << ['-Wno-unused-parameter'] // sokol_app.h

	// TODO V compile warnings - here to make the compiler(s) shut up :/
	cflags << ['-Wno-unused-variable', '-Wno-unused-result', '-Wno-unused-function',
		'-Wno-unused-label']
	cflags << ['-Wno-missing-braces', '-Werror=implicit-function-declaration']
	cflags << ['-Wno-enum-conversion', '-Wno-unused-value', '-Wno-pointer-sign',
		'-Wno-incompatible-pointer-types']

	defines << '-DAPPNAME="${opt.lib_name}"'
	defines << ['-DANDROID', '-D__ANDROID__', '-DANDROIDVERSION=${opt.api_level}']

	// Include NDK headers
	mut android_includes := []string{}
	ndk_sysroot := ndk.sysroot_path(opt.ndk_version) or {
		return error('${err_sig}: getting NDK sysroot path.\n${err}')
	}
	android_includes << '-I"' + os.join_path(ndk_sysroot, 'usr', 'include') + '"'
	android_includes << '-I"' + os.join_path(ndk_sysroot, 'usr', 'include', 'android') + '"'

	is_debug_build := opt.is_debug_build()

	// add needed flags for raylib
	ldflags << '-lEGL'
	ldflags << '-lGLESv2'
	ldflags << '-u ANativeActivity_onCreate'
	ldflags << '-lOpenSLES'

	if uses_gc {
		includes << '-I"' + os.join_path(v_thirdparty_dir, 'libgc', 'include') + '"'
	}

	// misc
	ldflags << ['-llog', '-landroid', '-lm']
	ldflags << ['-shared'] // <- Android loads native code via a library in NativeActivity

	mut cflags_arm64 := ['-m64']
	mut cflags_arm32 := ['-mfloat-abi=softfp', '-m32']
	mut cflags_x86 := ['-march=i686', '-mssse3', '-mfpmath=sse', '-m32']
	mut cflags_x86_64 := ['-march=x86-64', '-msse4.2', '-mpopcnt', '-m64']

	mut arch_cc := map[string]string{}
	mut arch_libs := map[string]string{}
	for arch in archs {		
		compiler := ndk.compiler(.c, opt.ndk_version, arch, opt.api_level) or {
			return error('${err_sig}: failed getting NDK compiler.\n${err}')
		}
		arch_cc[arch] = compiler

		arch_lib := ndk.libs_path(opt.ndk_version, arch, opt.api_level) or {
			return error('${err_sig}: failed getting NDK libs path.\n${err}')
		}
		arch_libs[arch] = arch_lib
	}

	mut arch_cflags := map[string][]string{}
	arch_cflags['arm64-v8a'] = cflags_arm64
	arch_cflags['armeabi-v7a'] = cflags_arm32
	arch_cflags['x86'] = cflags_x86
	arch_cflags['x86_64'] = cflags_x86_64

	if opt.verbosity > 0 {
		println('Compiling C output for ${archs}' + if opt.parallel { ' in parallel' } else { '' })
	}

	mut jobs := []job_util.ShellJob{}

	for arch in archs {
		arch_cflags[arch] << [
			'-target ' + ndk.compiler_triplet(arch) + opt.min_sdk_version.str(),
		]
		if arch == 'armeabi-v7a' {
			arch_cflags[arch] << ['-march=armv7-a']
		}
	}

	// Cross compile v.c to v.o lib files
	for arch in archs {
		arch_o_dir := os.join_path(build_dir, 'o', arch)
		if !os.is_dir(arch_o_dir) {
			os.mkdir_all(arch_o_dir) or {
				return error('${err_sig}: failed making directory "${arch_o_dir}". ${err}')
			}
		}

		arch_o_file := os.join_path(arch_o_dir, '${opt.lib_name}.o')
		// Compile .o
		build_cmd := [
			'-l:build/${arch}/libraylib.a'
			arch_cc[arch],
			cflags.join(' '),
			android_includes.join(' '),
			includes.join(' '),
			defines.join(' '),
			arch_cflags[arch].join(' '),
			'-c "${v_output_file}"',
			'-o "${arch_o_file}"',
		]

		o_files[arch] << arch_o_file

		jobs << job_util.ShellJob{
			cmd: build_cmd
		}
	}

	job_util.run_jobs(jobs, opt.parallel, opt.verbosity) or {
		return IError(CompileError{
			kind: .c_to_o
			err: err.msg()
		})
	}
	jobs.clear()

	if opt.no_so_build && opt.verbosity > 1 {
		println('Skipping .so build since .no_so_build == true')
	}

	// Cross compile .o files to .so lib file
	if !opt.no_so_build {
		for arch in archs {
			arch_lib_dir := os.join_path(build_dir, 'lib', arch)
			os.mkdir_all(arch_lib_dir) or {
				return error('${err_sig}: failed making directory "${arch_lib_dir}".\n${err}')
			}

			arch_o_files := o_files[arch].map('"${it}"')
			arch_a_files := a_files[arch].map('"${it}"')

			mut build_cmd := [
				arch_cc[arch],
				arch_o_files.join(' '),
				'-o "${arch_lib_dir}/lib${opt.lib_name}.so"',
				arch_a_files.join(' '),
				'-L"' + arch_libs[arch] + '"',
				ldflags.join(' '),
			]
			lflags := os.join_path(vxt.vmodules() or {
				return error('${err_sig}:vmodules folder not found')
			}, 'vab', 'raylib', 'build', arch)

			// add the compiled raylib libraries for each arch
			if is_raylib {
				build_cmd << '-L ${lflags}'
			}

			jobs << job_util.ShellJob{
				cmd: build_cmd
			}
		}

		job_util.run_jobs(jobs, opt.parallel, opt.verbosity) or {
			return IError(CompileError{
				kind: .o_to_so
				err: err.msg()
			})
		}

		if 'armeabi-v7a' in archs {
			// TODO fix DT_NAME crash instead of including a copy of the armeabi-v7a lib
			armeabi_lib_dir := os.join_path(build_dir, 'lib', 'armeabi')
			os.mkdir_all(armeabi_lib_dir) or {
				return error('${err_sig}: failed making directory "${armeabi_lib_dir}".\n${err}')
			}

			armeabi_lib_src := os.join_path(build_dir, 'lib', 'armeabi-v7a', 'lib${opt.lib_name}.so')
			armeabi_lib_dst := os.join_path(armeabi_lib_dir, 'lib${opt.lib_name}.so')
			os.cp(armeabi_lib_src, armeabi_lib_dst) or {
				return error('${err_sig}: failed copying "${armeabi_lib_src}" to "${armeabi_lib_dst}".\n${err}')
			}
		}
	}
	// !opt.no_so_build
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

	util.verbosity_print_cmd(v_cmd, opt.verbosity)
	v_dump_res := util.run(v_cmd)
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
pub fn compile_v_imports_c_dependencies(opt CompileOptions, imported_modules []string) !VImportCDeps {
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

	mut jobs := []job_util.ShellJob{}
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
			util.verbosity_print_cmd(build_cmd, opt.verbosity)
			o_res := util.run_or_error(build_cmd)!
			if opt.verbosity > 2 {
				eprintln(o_res)
			}

			o_files[arch] << o_file

			jobs << job_util.ShellJob{
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

			jobs << job_util.ShellJob{
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

			jobs << job_util.ShellJob{
				cmd: build_cmd
			}
		}
	}

	job_util.run_jobs(jobs, opt.parallel, opt.verbosity)!

	return VImportCDeps{
		o_files: o_files
		a_files: a_files
	}
}
			

			
