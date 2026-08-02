let isPlaying = true;

function Effect() {
    var self = this;
    var time = 0;
    var delay = 4500;

    this.play = function () {
        var now = (new Date()).getTime();

        if (now > time && isSmile(world.landmarks, world.latents)) {
            Api.meshfxMsg("animOnce", 0, 0, "Take 001");
            Api.hideHint();
            Api.playSound("cat.ogg", false, 1);
            time = now + delay;
        }
    };

    this.init = function () {
        var now = (new Date()).getTime();
        Api.meshfxMsg("spawn", 3, 0, "!glfx_FACE");
        Api.meshfxMsg("spawn", 0, 0, "PinkHandCat.bsm2");
        Api.meshfxMsg("spawn", 1, 0, "PinkHead.bsm2");
        Api.meshfxMsg("spawn", 2, 0, "morph.bsm2");
        Api.meshfxMsg("spawn", 2, 0, "hair.bsm2");
        Api.playVideo("frx", true, 1.0);

        self.faceActions = [self.play];
        isPlaying && Api.playSound("music.ogg", true, 1);
        Api.showHint("Smile");
        Api.playVideo("frx", true, 1);

        Api.showRecordButton();
    };

    this.restart = function () {
        Api.meshfxReset();
        Api.stopVideo("frx");
        Api.stopSound("music.ogg");
        Api.stopSound("cat.ogg");
        self.init();
    };

    this.faceActions = [];
    this.noFaceActions = [];

    this.videoRecordStartActions = [];
    this.videoRecordFinishActions = [];
    this.videoRecordDiscardActions = [this.restart];
}

function stopMusic(){
    isPlaying = false;
    Api.stopSound("music.ogg");
}

configure(new Effect());

const warpHair = (inner, outer, mid, strength) => {
    bnb.scene.getAssetManager().findMaterial("shaders/warp_hair").findParameter("u_hair").setVector4(new bnb.Vec4(inner, outer, mid, strength))
  }
  
  warpHair(80, 250, 0.1, 0.3)