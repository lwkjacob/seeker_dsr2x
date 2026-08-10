fx_version 'cerulean'
game 'gta5'

name 'seeker_dsr2x'
description 'SEEKER DSR 2X Radar - dual simultaneous front/rear target and fast windows'
author 'lwkjacob'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'client/utils.lua',
    'client/player.lua',
    'client/radar.lua',
    'client/sync.lua',
    'client/exports.lua',
}

server_scripts {
    'server/sync.lua',
    'server/exports.lua',
    'server/alpr.lua',
}

escrow_ignore {
    'shared/config.lua',
    'client/utils.lua',
    'client/player.lua',
    'client/radar.lua',
    'client/sync.lua',
    'client/exports.lua',
    'server/sync.lua',
    'server/exports.lua',
    'server/alpr.lua',
}

ui_page 'nui/index.html'

files {
    'nui/index.html',
    'nui/style.css',
    'nui/app.js',
    'nui/font/Segment7Standard.otf',

    'nui/images/seeker_dsr2x_base.png',
    'nui/images/seeker_dsr2x_remote.png',

    -- Top row (FRONT antenna) status lamps
    'nui/images/top_same_on.png',
    'nui/images/top_opp_on.png',
    'nui/images/top_xmit_on.png',
    'nui/images/top_front_on.png',
    'nui/images/top_rear_on.png',
    'nui/images/top_fast_on.png',
    'nui/images/top_lock_on.png',

    -- Bottom row (REAR antenna) status lamps
    'nui/images/bottom_same_on.png',
    'nui/images/bottom_opp_on.png',
    'nui/images/bottom_xmit_on.png',
    'nui/images/bottom_front_on.png',
    'nui/images/bottom_rear_on.png',
    'nui/images/bottom_fast_on.png',
    'nui/images/bottom_lock_on.png',

    -- Direction arrows beside the TARGET windows
    'nui/images/target_top_front_arrow_on.png',
    'nui/images/target_top_rear_arrow_on.png',
    'nui/images/target_bottom_front_arrow_on.png',
    'nui/images/target_bottom_rear_arrow_on.png',

    -- Direction arrows beside the FAST/LOCK windows
    'nui/images/fast_top_front_arrow_on.png',
    'nui/images/fast_top_rear_arrow_on.png',
    'nui/images/fast_bottom_front_arrow_on.png',
    'nui/images/fast_bottom_rear_arrow_on.png',

    -- Plate reader
    'nui/images/plates/platereader.png',
    'nui/images/plates/0.png',
    'nui/images/plates/1.png',
    'nui/images/plates/2.png',
    'nui/images/plates/3.png',
    'nui/images/plates/4.png',
    'nui/images/plates/5.png',

    -- Audio
    'nui/sounds/XmitOn.wav',
    'nui/sounds/XmitOff.wav',
    'nui/sounds/Beep.wav',
    'nui/sounds/Away.wav',
    'nui/sounds/Closing.wav',
    'nui/sounds/Front.wav',
    'nui/sounds/Rear.wav',
    -- Middle word of the 3-word enunciator (antenna / mode / direction). Optional:
    -- app.js skips any word whose sample is missing, degrading to the 2-word phrase.
    'nui/sounds/Stationary.wav',
    'nui/sounds/Opposite.wav',
    'nui/sounds/Same.wav',
    'nui/sounds/doppler/0.wav',
    'nui/sounds/alpr_hit.wav',
    'nui/sounds/stupidfuckinghappysound.wav',
}

dependencies {
    'ox_lib',
}

exports {
    'GetRadarState',
    'GetRadarDetailedState',
    'IsRadarActive',
    'IsRadarDisplayed',
    'CanControlRadar',
    'CanViewRadar',
}

server_exports {
    'GetPlayerRadarState',
    'IsPlayerRadarActive',
}
