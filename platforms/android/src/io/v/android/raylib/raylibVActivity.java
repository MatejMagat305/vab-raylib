package io.v.android.raylib;

import android.app.NativeActivity;

public class VRaylibActivity extends NativeActivity {
	static { 
    System.loadLibrary("v");
  }
	private static VActivity thiz;
	// Set instance reference
	public VActivity() { thiz = this; }
	public static VActivity getVActivity() {
		return thiz;
	}
}
