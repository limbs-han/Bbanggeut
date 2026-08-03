var settings = {
    effectName: "HawaiiHairFlower"
};

var spendTime = 0;

var delay = 4000; // ms

var analytic = {
    spendTimeSec: 0,
    taps: 0,
    videoCountOnMasks: {
        subEffect1: {soundOnCount: 0, soundOffCount: 0}
    },
};

let isPlaying = true;


function sendAnalyticsData() {
    var _analytic;
    analytic.spendTimeSec = Math.round(spendTime / 1000);
    _analytic = {
        'Event Name': 'Effects Stats',
        'Effect Name': settings.effectName,
        'Effect Action': 'Tap',
        'Action Count': String(analytic.taps),
        'Spend Time': String(analytic.spendTimeSec),
        'Video Analytics 1 SoundOn': String(analytic.videoCountOnMasks.subEffect1.soundOnCount),
        'Video Analytics 1 SoundOff': String(analytic.videoCountOnMasks.subEffect1.soundOffCount)
    };
    Api.print('sended analytic: ' + JSON.stringify(_analytic));
    Api.effectEvent('analytic', _analytic);
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

function onTouchesBegan(touches) {
    //Api.hideHint();
    analytic.taps++;
    //Add your logic
}
// --> add to function Effect() FROM HERE

// --> TO HERE 

function Effect() {
    var self = this;

    this.meshes = [
        { file: "hawaiiFlower.bsm2", anims: [
            { a: "CINEMA_4D_Main", t: 1000 },
        ] },
        { file: "BeautyFaceSP.bsm2", anims: [
            { a: "CINEMA_4D_Main", t: 1000 },
        ] },
    ];

    this.play = function() {
        var now = (new Date()).getTime();
        for(var i = 0; i < self.meshes.length; i++) {
            if(now > self.meshes[i].endTime) {
                self.meshes[i].animIdx = (self.meshes[i].animIdx + 1)%self.meshes[i].anims.length;
                Api.meshfxMsg("animOnce", i, 0, self.meshes[i].anims[self.meshes[i].animIdx].a);
                self.meshes[i].endTime = now + self.meshes[i].anims[self.meshes[i].animIdx].t;
            }
        }

        // if(Api.isMouthOpen()) {
        //  Api.hideHint();
        // }
    };

    this.init = function() {
        Api.meshfxMsg("spawn", 2, 0, "!glfx_FACE");

        Api.meshfxMsg("spawn", 0, 0, "hawaiiFlower.bsm2");
        // Api.meshfxMsg("animOnce", 0, 0, "CINEMA_4D_Main");

        Api.meshfxMsg("spawn", 1, 0, "BeautyFaceSP.bsm2");
        // Api.meshfxMsg("animOnce", 1, 0, "CINEMA_4D_Main");

        Api.playVideo("foreground",true,1);

        // Api.showHint("Open mouth");
        // Api.playVideo("frx",true,1);
        isPlaying && Api.playSound("music.ogg",true,1);
        Api.showRecordButton();
    };

    this.restart = function() {
        Api.meshfxReset();
        // Api.stopVideo("frx");
        Api.stopSound("music.ogg");
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

    this.videoRecordStartActions = [onVideoStart];
    this.videoRecordFinishActions = [];
    this.videoRecordDiscardActions = [this.restart];
}

configure(new Effect());

function onVideoStart(){
    analytic.videoCountOnMasks.subEffect1.soundOffCount++;
}
function stopMusic(){
    isPlaying = false;
    Api.stopSound("music.ogg");

}