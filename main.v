module main

import os
import flag
import vab.cli
import vab.util
import vab.android

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
	compile_raylib(comp_opt, opt) or {
		util.vab_error('Compiling did not succeed', details: '${err}')
		exit(1)
	}
	// =================================

	apo := opt.as_android_package_options()
	pck_opt := android.PackageOptions{
		...apo
		keystore: keystore
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