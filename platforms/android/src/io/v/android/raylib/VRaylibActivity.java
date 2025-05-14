package io.v.android.raylib;

import android.app.NativeActivity;

public class VRaylibActivity extends NativeActivity {
	static { 
    System.loadLibrary("v");
  }
	private static VRaylibActivity thiz;
	// Set instance reference
	public VRaylibActivity() { thiz = this; }
	public static VRaylibActivity getVActivity() {
		return thiz;
	}
}

