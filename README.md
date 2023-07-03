This is the demo app that is part of the
["Building Offline-First Flutter Apps with Couchbase Lite"](fluttercon.dev/gabriel-terwesten/)
talk at FlutterCon 2023.

## Getting Started

To enable data synchronization in the app you need to have a Couchbase Cluster
running:

```bash
cd backend
./init-couchbase-cluster.sh
```

This will start a Couchbase Server instance and a Couchbase Sync Gateway
instance in Docker containers and configure them for the app.

Since the Couchbase Cluster is running locally, it is not directly accessible
from an Android Emulator or real devices. It is easiest to explore the app using
the iOS Simulator or to run the desktop version of the app.

To run the app, use your IDE or the command line:

```bash
flutter run
```
