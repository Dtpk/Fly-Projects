# Fly-Projects
             -The fruit fly connectome and some unique projects using it.-


<p align="center">
  <a href="https://www.youtube.com/watch?v=3aTu1EkrrDY">
    <img src="https://github.com/user-attachments/assets/74df30e8-58d0-47af-9acc-fdd263a327f5" alt="Watch the video" width="800">
  </a>
</p>


NOTICE!!! All these projects use a VENV for no system bloat they will set up and run where the script is ran from!!
Also if you don't provide the csv files from "https://codex.flywire.ai" it will use a mock recreation not the real deal and will say it in the title bar.

It should be called "connections_princeton.csv" and "neurons.csv" I will see if I can provide it then but they go next to the scripts.

So in this repository you will see a few fruit fly based python projects using a real fruit fly brain "connectome" for the reasoning.

Not only do our flys see through walls using wifi to motion detect they can also manage your files and play a game in this case halo 2 but any game with a radar should work.

A few of these are vibe coded it is a lot of project to work on all at once so I kinda feel like a fly on the wall with this one but I seen no one trying it so I wanted to make some new
use cases for the fruit fly connectome others didn't try yet or think of.

    -- Fly-Dar --

(video place holder)

Background rssi values used for person based tracker. I tried this in the past scripting it my self but with the fruit fly connectome added this makes it way more stable and easy to configure cause the fruit fly can judge what is a standard "normal" and react on its own. 
The one slider adjust its "normal" state I like 10 seconds but you could tweak lower or higher it really depends on the networking tool used and if your hardware can refresh the rssi values fast enough using nmcli. Oh yeah you will need to install nmcli or iw but I might include both version but right now it is for nmcli its output is just cleaner. That and python are the only packages you need for the "fly-Dar" to work.

UPDATE fly-dar-learning version

This one does as it says it can learn some what adjusting the weights then it will fall back after awhile, and it has more node selection choices you can even load the whole thing in a sparce form this is very very un-optimized it lags I will work on it if we can't get a visual it might be dropped for just smooth fps that why the full connectome is its own option. This one isnt as static nor does it use a random selection of neurons unless you tell it.

It might need tweaking for cpu use or nvidia I will try some stuff then so if you run into issues know system compatibly is a bit unstable compared to the static non learning one.

    -- Fly-Manager --

(video place holder)

This I wanted to make look like dolphin but with a lot more buzz admittedly pygame isn't the best to act as a file manager but you can drag and drop and have a auto toggle set you configure the txt file made next to the script with the dirs you want then run the script. After that if you hit the toggle if the fly sees 2 files going at once everything in the dir is removed for the 2 files that just went in. This is useful for only keeping the first few logs and only when 2 happen at the same time it removes them all. This could use more work or settings so any ideas are welcomed. The fly will alert you when a file is made or deleted and you can drag and drop files to add them to your folders directly with the "Fly-Manager" This one had some slight changes compared to the video but still behaves the same way all that is included is file managing copy or move settings fullscreen or not full screen title bar or no title bar and a music detector so the fly can mellow out with music.

    -- By-The-Flys-Gaming --

(video place holder)

This is for x11 not wayland!! Also fixed so no set up besides making sure the "connections_princeton.csv" and "neurons.csv" are placed next to the app.py in the venv if not the system falls back to a fake "mock" brain.

Also make sure the radar aligns with the radar in the game this also mimics a gamepad so any game with a gamepad you can plug in while running this will work on. You will need to adjust the sliders so the fly gets the best chance at playing the game. "WILL BE TWEAKING THIS PROJECT MORE SO EXPECT A FEW CHANGES IN TIME"
This one uses flask for a web interface something I am more use to then pygame so if it seems more polished you know why it will also display if it using the "mock" brain or using your "real" connectome.

Eventually adding a virtual gamepad to the page so you can navigate manually some games might need that I think.

Watch the video to learn more and see them in action!!! "https://www.youtube.com/watch?v=3aTu1EkrrDY"
    
    -- Fruit-Fly-Security --

Work in progress but the fruit-fly will only stand guard and track your local phones ip when provided / wifi outages, and do much better motion detection this is really just a dumb personal project for a home server I have and am getting tired of some false positives and having to manually start it. This wasn't in the YouTube video. And this might go through a few changes as I tune which neurons I should use for solid reliability with the camera. Will be released when its released since i'm using this one a lot and have a great baseline now I wanna take my time on this one since it might see daily use.
    
    -- Special notes --

A heads up I am working on a selector or load as needed method right now it grabs a random 64 nodes for the file manage and the fly-dar the fly-dar will get a fly-dar-learning version which will have a selector letting you use more specific sections "etc" and it will learn and adjust the weights not just be static not sure if this will improve it more but it a start. "central" "motor" "sensory" so on and so forth from 100 to 64 will be select-able perhaps more as I work on it.

If your wondering why not load the full connectome thing? It would consume more then 102gb of ram or more which is why lots of other projects just use a section like I been doing or they do a sparce trick where it loads as needed which I am looking into as well. Again more eyes and help will improve the project.
