SOURCE_DIR = assets/bridge/node_modules/@neteasecloudmusicapienhanced/api
TARGET_DIR = assets/bridge/dist

cp -r $SOURCE_DIR/data $TARGET_DIR
cp -r $SOURCE_DIR/module $TARGET_DIR
cp -r $SOURCE_DIR/util $TARGET_DIR
cp $SOURCE_DIR/server.js $TARGET_DIR