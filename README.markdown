dhttpsproxy
================

About
-----

dhttpsproxy is a working and small http[s]? mitm proxy.


Getting Started
---------------

1. start the deamon
		lem proxy.lua
	

2. point a browser to: http://localhost:8000/
	
3. On a terminal type

		export http_proxy=localhost:8888
		export https_proxy=localhost:8888
		curl example.com


4. you should be able to see your request / reply on your browser.

Preview
-----

![proxy-view](https://user-images.githubusercontent.com/10823818/36488998-29f80fa8-1725-11e8-8771-c68ad4ce9686.png)

    
Contact
-------

Please send bug reports, patches and feature requests to me <ra@apathie.net>.
