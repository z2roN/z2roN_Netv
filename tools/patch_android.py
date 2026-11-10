# flutter create 로 만들어진 안드로이드 프로젝트에 z2roN Net 설정을 덧씌웁니다.
#  - 권한(인터넷/네트워크/Wi-Fi/위치), 앱 이름
#  - MainActivity.kt (네트워크 정보를 읽는 코드), 앱 아이콘
import glob, os, re, shutil, sys

app = sys.argv[1]
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
main = os.path.join(app, "android", "app", "src", "main")

# 1) 매니페스트: 권한 + 앱 이름
mf = os.path.join(main, "AndroidManifest.xml")
s = open(mf, encoding="utf-8").read()
perms = """    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
    """
if "ACCESS_WIFI_STATE" not in s:
    s = s.replace("<application", perms + "<application", 1)
s = re.sub(r'android:label="[^"]*"', 'android:label="z2roN Net"', s, count=1)
open(mf, "w", encoding="utf-8").write(s)

# 2) MainActivity.kt 교체
kdir = os.path.join(main, "kotlin", "com", "z2ron", "z2ron_net")
for old in glob.glob(os.path.join(main, "kotlin", "**", "MainActivity.*"), recursive=True) + glob.glob(os.path.join(main, "java", "**", "MainActivity.*"), recursive=True):
    os.remove(old)
os.makedirs(kdir, exist_ok=True)
shutil.copy(os.path.join(root, "android_patch", "MainActivity.kt"), os.path.join(kdir, "MainActivity.kt"))

# 3) 아이콘
for d in ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"):
    src = os.path.join(root, "android_patch", "icons", d + ".png")
    dst = os.path.join(main, "res", "mipmap-" + d)
    if os.path.exists(src) and os.path.isdir(dst):
        shutil.copy(src, os.path.join(dst, "ic_launcher.png"))
print("patched", app)
