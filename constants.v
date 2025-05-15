module main
import vab.cli

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

const accepted_input_files = ['.v', '.apk', '.aab']