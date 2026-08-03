var settings = {
    effectName: "1001Nights"
}

var spendTime = 0;
var analytic = {
    spendTimeSec: 0
}

function sendAnalyticsData() {
    var _analytic;
    analytic.spendTimeSec = Math.round(spendTime / 1000);
    _analytic = {
        "Event Name": "Effects Stats",
        "Effect Name": settings.effectName,
        "Spend Time": String(analytic.spendTimeSec)
    };
    Api.print("sended analytic: " + JSON.stringify(_analytic));
    Api.effectEvent("analytic", _analytic);
}

function Effect() {
    var self = this;

    this.init = function () {
        Api.meshfxMsg("spawn", 3, 0, "!glfx_FACE");

        Api.meshfxMsg("spawn", 0, 0, "mod_physics.bsm2");
        /*
Point009
Dummy001
Point002        -> Point009
Point013
Point011
Point008
Point014
Point012
root_R_lock
root_L_lock
CATRigtail_L_1  -> root_L_lock
CATRigtail_L_2  -> CATRigtail_L_1
CATRigtail_L_3  -> CATRigtail_L_2
CATRigtail_R_1  -> root_R_lock
CATRigtail_R_2  -> CATRigtail_R_1
CATRigtail_R_3  -> CATRigtail_R_2
Point003        -> Point002
Point006        -> Point013
Point004        -> Point011
Point001        -> Point008
Point007        -> Point014
Point005        -> Point012
        */

        Api.meshfxMsg("dynImass", 0, 0, "Point009");
        Api.meshfxMsg("dynImass", 0, 0, "Dummy001");
        Api.meshfxMsg("dynImass", 0, 0, "Point013");
        Api.meshfxMsg("dynImass", 0, 0, "Point011");
        Api.meshfxMsg("dynImass", 0, 0, "Point008");
        Api.meshfxMsg("dynImass", 0, 0, "Point014");
        Api.meshfxMsg("dynImass", 0, 0, "Point012");

        Api.meshfxMsg("dynImass", 0, 0, "Point006");
        Api.meshfxMsg("dynImass", 0, 0, "Point004");
        Api.meshfxMsg("dynImass", 0, 0, "Point001");
        Api.meshfxMsg("dynImass", 0, 0, "Point007");
        Api.meshfxMsg("dynImass", 0, 0, "Point005");

        Api.meshfxMsg("dynImass", 0, 0, "root_R_lock");
        Api.meshfxMsg("dynImass", 0, 0, "root_L_lock");

        Api.meshfxMsg("dynSphere", 0, 0, "0 21 10 85");
        Api.meshfxMsg("dynSphere", 0, 1, "0 -36 -10 86");

        Api.meshfxMsg("dynGravity", 0, 0, "0 -2000 0");
        Api.meshfxMsg("dynDamping", 0, 98)

        Api.meshfxMsg("spawn", 1, 0, "mod.bsm2");
        Api.meshfxMsg("spawn", 2, 0, "BeautyFace.bsm2");
        
        Api.showRecordButton();
    };

    this.restart = function () {
        Api.meshfxReset();
        self.init();
    };

    this.timeUpdate = function () {
        if (self.lastTime === undefined) self.lastTime = (new Date()).getTime();

        var now = (new Date()).getTime();
        self.delta = now - self.lastTime;
        if (self.delta < 3000) { // dont count spend time if application is minimized
            spendTime += self.delta;
        }
        self.lastTime = now;
    };

    this.faceActions = [this.timeUpdate];
    this.noFaceActions = [this.timeUpdate];

    this.videoRecordStartActions = [];
    this.videoRecordFinishActions = [];
    this.videoRecordDiscardActions = [this.restart];
}

function onStop() {
    try {
        sendAnalyticsData();
    } catch (err) {
        Api.print(err);
    }
}

function onFinish() {
    try {
        sendAnalyticsData();
    } catch (err) {
        Api.print(err);
    }
}

configure(new Effect());