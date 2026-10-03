# Randopitons patch

L'application Randopitons n'est plus maintenue. Sur les téléphones Android récents qui ne fonctionnent plus qu'en 64 bits, elle plante dès le lancement.

## Installation sur le téléphone

| ⚠️ N'installez jamais un fichier dont vous ne connaissez pas l'origine, y compris celui-ci. Utilisez un scanner de fichier comme [virus total](https://www.virustotal.com/gui/) avant de l'installer.

Télécharger le fichier [randopiton_2.1.5_patch.xapk](https://github.com/Sarapuce/randopiton-patch/releases/tag/2.1.5-patch), puis installer ce fichier avec un installateur de fichier xpak (trouvable facilement sur le playstore).

Testé sur un Pixel 9 sous Android 17 (API 37).

## Contenu

Ce dépôt contient un script qui corrige ce crash en modifiant une seule ligne de l'application. Il ne contient aucun fichier de l'application : il faut fournir soi-même le fichier `.xapk` de la version 2.1.5. Ce fichier est assez facilement trouvable en cherchant sur google "randopiton apk".

## Utilisation

```sh
./patch.sh Randopitons_2.1.5_APKPure.xapk
```

Les APK corrigés sont créés dans `out/`. On peut choisir un autre dossier en deuxième argument :

```sh
./patch.sh Randopitons_2.1.5_APKPure.xapk mon_dossier
```

## Contenu du dépôt

Ce dépôt contient le script de patch de l'application, exécutable avec Linux, macOS ou WSL. 

Les prérequis pour exécuter le script : 
- Le fichier `.xapk` de Randopitons 2.1.5, par exemple `Randopitons_2.1.5_APKPure.xapk`
- Java (testé avec OpenJDK 22)
- [apktool](https://apktool.org/) (testé avec la version 2.7.0)
- Android SDK build-tools, pour `zipalign` et `apksigner` (testé avec la version 35.0.0)
- `zip`, `unzip`, `keytool` (fourni avec Java)
- `adb`, pour installer l'application sur le téléphone

Par défaut, le script utilise la version de build-tools la plus récente trouvée dans `$ANDROID_HOME` (ou `~/Android/Sdk`). On peut en imposer une avec la variable `BUILD_TOOLS`.

## Cause technique

L'application est construite avec Expo SDK 40 (React Native) et embarque une ancienne version de **SoLoader**, la bibliothèque de Facebook qui charge les bibliothèques natives (`.so`).

1. À l'initialisation, SoLoader lit la variable d'environnement `LD_LIBRARY_PATH` pour savoir où se trouvent les bibliothèques système. Sur Android récent, cette variable est vide.
2. SoLoader se rabat alors sur une valeur par défaut codée en dur : `/vendor/lib:/system/lib`. Ce sont les répertoires 32 bits.
3. Les téléphones récents (Pixel 7 et suivants, entre autres) n'ont plus de bibliothèques 32 bits : `/system/lib` ne contient plus `libc.so`.
4. Le chargement du moteur JavaScript JSC (`libjscexecutor.so` → … → `libc.so`) échoue donc :
   ```
   E SoLoader: couldn't find DSO to load: libjscexecutor.so caused by: couldn't find DSO to load: libfb.so
     caused by: couldn't find DSO to load: libc++_shared.so caused by: couldn't find DSO to load: libc.so
   ```
5. React Native essaie alors le moteur Hermes, qui n'est pas embarqué dans l'application, et plante sur `libhermes.so`.

## Correctif

Dans `SoLoader.init`, on remplace la valeur par défaut par une liste qui donne la priorité aux répertoires 64 bits (voir [`patches/soloader-lib64.diff`](patches/soloader-lib64.diff)) :

```diff
--- a/smali/com/facebook/soloader/SoLoader.smali
+++ b/smali/com/facebook/soloader/SoLoader.smali
@@ -1401,7 +1401,7 @@
 
     if-nez v2, :cond_0
 
-    const-string v2, "/vendor/lib:/system/lib"
+    const-string v2, "/system/lib64:/vendor/lib64:/system/lib:/vendor/lib"
 
     :cond_0
     const-string v3, ":"
```

Les chemins 32 bits restent en fin de liste. Le comportement est donc inchangé sur les anciens appareils 32 bits.
