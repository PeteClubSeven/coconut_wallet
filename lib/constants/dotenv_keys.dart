class DotenvKeys {
  static const String apiHost = 'API_HOST';
  static const String networkType = 'NETWORK_TYPE';

  // Optional regtest overrides, for running against a self-hosted regtest stack
  static const String mempoolUrl = 'MEMPOOL_URL';
  static const String electrumServer = 'ELECTRUM_SERVER';

  // Ark (bark). The Ark feature is enabled only when ARK_SERVER_URL is set.
  static const String arkServerUrl = 'ARK_SERVER_URL';
  static const String arkEsploraUrl = 'ARK_ESPLORA_URL';

  // Firebase
  static const String firebaseApiKeyAndroid = 'FIREBASE_API_KEY_ANDROID';
  static const String firebaseAppIdAndroid = 'FIREBASE_APP_ID_ANDROID';
  static const String firebaseMessagingSenderId = 'FIREBASE_MESSAGING_SENDER_ID';
  static const String firebaseProjectId = 'FIREBASE_PROJECT_ID';
  static const String firebaseStorageBucket = 'FIREBASE_STORAGE_BUCKET';
  static const String firebaseApiKeyIos = 'FIREBASE_API_KEY_IOS';
  static const String firebaseAppIdIos = 'FIREBASE_APP_ID_IOS';
  static const String firebaseIosBundleId = 'FIREBASE_IOS_BUNDLE_ID';
}
