package local.apkexporter;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Looper;
import org.json.JSONArray;
import org.json.JSONObject;

/** Runs as the existing ADB shell user; never installed as an Android app. */
public final class AppCatalog {
    public static void main(String[] args) {
        try {
            Looper.prepareMainLooper();
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            Object thread = activityThread.getMethod("systemMain").invoke(null);
            Context context = (Context) activityThread.getMethod("getSystemContext").invoke(thread);
            PackageManager pm = context.getPackageManager();
            boolean includeSystem = args.length > 0 && "all".equals(args[0]);
            JSONArray apps = new JSONArray();
            for (ApplicationInfo info : pm.getInstalledApplications(0)) {
                if (!includeSystem && (info.flags & ApplicationInfo.FLAG_SYSTEM) != 0) continue;
                String name = info.packageName;
                try {
                    CharSequence label = pm.getApplicationLabel(info);
                    if (label != null && !label.toString().trim().isEmpty()) name = label.toString();
                } catch (RuntimeException ignored) {
                    // One broken/unavailable APK must not prevent listing the others.
                }
                JSONObject app = new JSONObject();
                app.put("id", info.packageName);
                app.put("name", name);
                apps.put(app);
            }
            // Android runtime diagnostics may precede stdout; mark the JSON payload.
            System.out.println("APK_EXPORTER_CATALOG:" + apps.toString());
            System.exit(0);
        } catch (Throwable error) {
            error.printStackTrace(System.err);
            System.exit(1);
        }
    }
}
