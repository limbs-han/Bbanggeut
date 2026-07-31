
function Effect() {
	var self = this;

	this.init = function() {
		Api.meshfxMsg("spawn", 0, 0, "rabbit.bsm2");
		Api.meshfxMsg("spawn", 1, 0, "zquad.bsm2");

		Api.showRecordButton();
	};

	this.faceActions = [];
	this.noFaceActions = [];

	this.videoRecordStartActions = [];
	this.videoRecordFinishActions = [];
	this.videoRecordDiscardActions = [];
}

configure(new Effect());
