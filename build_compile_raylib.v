module main

import os
import vab.cli
import vab.vxt
import vab.util
import vab.android
import vab.android.ndk
import crypto.md5

fn build_raylib(opt android.CompileOptions, raylib_path string, arch string) ! {
	build_path := os.join_path(raylib_path, 'build')
	// check if the library already exists or compile it
	if os.exists(os.join_path(build_path, arch, 'libraylib.a')) {
		return
	} else {
		src_path := os.join_path(raylib_path, 'src')
		ndk_path := ndk.root_version(opt.ndk_version)
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
		if opt.verbosity > 0 {
			println('make -C ${src_path} PLATFORM=PLATFORM_ANDROID ANDROID_NDK=${ndk_path} ANDROID_ARCH=${arch_name} ANDROID_API_VERSION=${opt.api_level} ')			
		}
		os.execute('make -C ${src_path} PLATFORM=PLATFORM_ANDROID ANDROID_NDK=${ndk_path} ANDROID_ARCH=${arch_name} ANDROID_API_VERSION=${opt.api_level} ')
		taget_path := os.join_path(build_path, arch)
		os.mkdir_all(taget_path) or { return error('failed making directory "${taget_path}"') }
		os.mv(os.join_path(src_path, 'libraylib.a'), taget_path) or {
			return error('failed to move .a file from ${src_path} to ${taget_path}')
		}
	}
}

fn download_raylib(raylib_c_path string) {
	// clone raylib from github
	os.execute('git clone https://github.com/raysan5/raylib.git ${raylib_c_path}')
}

pub fn compile_raylib(opt android.CompileOptions, cliO cli.Options) ! {
	err_sig := @MOD + '.' + @FN
	os.mkdir_all(opt.work_dir) or {
		return error('${err_sig}: failed making directory "${opt.work_dir}". ${err}')
	}
	build_dir := opt.build_directory()!

	v_meta_dump := android.compile_v_to_c(opt) or {
		return IError(android.CompileError{
			kind: .v_to_c
			err:  err.msg()
		})
	}

	is_raylib := 'raylib' in v_meta_dump.imports

	// check if raylib floder is found else clone it
	if !is_raylib {
		return error('vab-raylib extension requires module `raylib` to be imported in the project...')
	}
	v_raylib_module_path := os.join_path(vxt.vmodules() or {
		return error('${err_sig}: vmodules folder not found')
	}, 'raylib')
	raylib_c_path := os.join_path(v_raylib_module_path, 'raylib_C_source')
	if os.exists(raylib_c_path) {
		for arch in opt.archs {
			build_raylib(opt, raylib_c_path, arch) or {
				return error('cant build raylib ERROR: ${err}')
			}
		}
	} else {
		download_raylib(raylib_c_path)
		for arch in opt.archs {
			build_raylib(opt, raylib_c_path, arch) or {
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
		return IError(android.CompileError{
			kind: .c_to_o
			err:  err.msg()
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

	// is_debug_build := opt.is_debug_build()

	// add needed flags for raylib
	ldflags << '-lEGL'
	ldflags << '-lGLESv2'
	ldflags << '-u ANativeActivity_onCreate'
	ldflags << '-lOpenSLES'
	ldflags << '-DPLATFORM_ANDROID'
	ldflags << '-DGRAPHICS_API_OPENGL_ES2'

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

	mut jobs := []util.ShellJob{}

	mut src_dir := os.join_path(raylib_c_path, 'src')
	includes << '-I"' + src_dir + '" '

	if opt.verbosity > 0 {
		println('Include ${src_dir}')
	}
	for arch in archs {
		mut build_dir0 := os.join_path(raylib_c_path, 'build', arch)
		if opt.verbosity > 1 {
			println('Include ${build_dir0}')
		}
		arch_cflags[arch] << [
			'-target ' + ndk.compiler_triplet(arch) + opt.min_sdk_version.str(),
			'-L"' + build_dir0 + '" ',
			'-L"' + src_dir + '" ',
			'-I"' + build_dir0 + '" ',
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
			arch_cc[arch],
			cflags.join(' '),
			android_includes.join(' '),
			includes.join(' '),
			defines.join(' '),
			arch_cflags[arch].join(' '),
			'-c "${v_output_file}"',
			'-l:libraylib.a',
			'-l:raylib',
			'-o "${arch_o_file}"',
		]

		o_files[arch] << arch_o_file

		jobs << util.ShellJob{
			cmd: build_cmd
		}
	}

	util.run_jobs(jobs, opt.parallel, opt.verbosity) or {
		return IError(android.CompileError{
			kind: .c_to_o
			err:  err.msg()
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

			jobs << util.ShellJob{
				cmd: build_cmd
			}
		}

		util.run_jobs(jobs, opt.parallel, opt.verbosity) or {
			return IError(android.CompileError{
				kind: .o_to_so
				err:  err.msg()
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
