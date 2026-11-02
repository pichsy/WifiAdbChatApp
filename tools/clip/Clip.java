import android.content.ClipData;
import android.os.IBinder;
import android.util.Base64;

import java.lang.reflect.Method;

/**
 * 以 shell 身份运行（app_process），把参数里的 base64 文本写入系统剪贴板。
 * 纯 adb 没有设置剪贴板的命令，这里用反射直接调 IClipboard（scrcpy 同款思路）。
 *
 * 用法: CLASSPATH=/data/local/tmp/adbtype-clip.jar app_process /system/bin Clip <base64>
 */
public final class Clip {

    public static void main(String[] args) {
        try {
            if (args.length < 1) {
                System.err.println("usage: Clip <base64-utf8>");
                System.exit(2);
            }

            String text = new String(Base64.decode(args[0], Base64.NO_WRAP), "UTF-8");
            ClipData clip = ClipData.newPlainText("ADBType", text);

            IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                    .getMethod("getService", String.class)
                    .invoke(null, "clipboard");
            if (binder == null) {
                System.err.println("clipboard service not found");
                System.exit(3);
            }

            Class<?> stub = Class.forName("android.content.IClipboard$Stub");
            Object service = stub.getMethod("asInterface", IBinder.class).invoke(null, binder);

            Throwable last = null;
            for (Method method : service.getClass().getMethods()) {
                if (!method.getName().equals("setPrimaryClip")) continue;
                Object[] callArgs = buildArgs(method.getParameterTypes(), clip);
                if (callArgs == null) continue;
                try {
                    method.invoke(service, callArgs);
                    System.out.println("OK setPrimaryClip/" + method.getParameterCount());
                    System.exit(0);
                } catch (Throwable t) {
                    last = t;
                }
            }
            if (last != null) last.printStackTrace();
            System.exit(4);
        } catch (Throwable t) {
            t.printStackTrace();
            System.exit(5);
        }
    }

    private static Object[] buildArgs(Class<?>[] types, ClipData clip) {
        Object[] values = new Object[types.length];
        for (int i = 0; i < types.length; i++) {
            Class<?> type = types[i];
            if (type == ClipData.class) {
                values[i] = clip;
            } else if (type == String.class) {
                values[i] = (i == 1) ? "com.android.shell" : null;
            } else if (type == int.class) {
                values[i] = 0;
            } else if (type == boolean.class) {
                values[i] = false;
            } else {
                return null;
            }
        }
        return values;
    }
}
