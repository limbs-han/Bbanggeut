function Effect() {
    var self = this;

    this.init = function() {
        Api.meshfxMsg("spawn", 0, 0, "!glfx_FACE");
        Api.meshfxMsg("spawn", 1, 0, "cut.bsm2");
        Api.meshfxMsg("spawn", 2, 0, "ray_ban.bsm2");
        Api.meshfxMsg("spawn", 3, 0, "morph.bsm2");
        Api.meshfxMsg("spawn", 3, 0, "shadow.bsm2");

        Api.showRecordButton();
    };

    this.restart = function() {
        Api.meshfxReset();
        self.init();
    };

    this.faceActions = [];
    this.noFaceActions = [];

    this.videoRecordStartActions = [];
    this.videoRecordFinishActions = [];
    this.videoRecordDiscardActions = [this.restart];
}

configure(new Effect());