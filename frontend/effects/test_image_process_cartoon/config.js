
function Effect()
{
    this.init = function() {
        Api.meshfxMsg("spawn", 0, 0, "tri.bsm2");
    };

    this.faceActions = [];
    this.noFaceActions = [];

    this.videoRecordStartActions = [];
    this.videoRecordFinishActions = [];
    this.videoRecordDiscardActions = [];
}

configure(new Effect());
