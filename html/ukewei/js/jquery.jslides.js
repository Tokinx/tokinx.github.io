/**
 * jQuery jslide 1.1.0
 *
 * http://www.cactussoft.cn
 *
 * Copyright (c) 2009 - 2013 Jerry
 *
 * Dual licensed under the MIT and GPL licenses:
 *   http://www.opensource.org/licenses/mit-license.php
 *   http://www.gnu.org/licenses/gpl.html
 */
$(function(){
	var numpic = $('#slide li').size()-1;
	var nownow = 0;
	var inout = 0;
	var TT = 0;
	var SPEED = 5000;


	$('#slide li').eq(0).siblings('li').css({'display':'none'});


	var ulstart = '<ul class="menu-nav">',
		ulcontent = '',
		ulend = '</ul>';
	ADDLI();
	var pagination = $('.menu-nav li');
	var paginationwidth = $('.menu-nav').width();
	
	pagination.eq(0).addClass('current')
		
	function ADDLI(){
		//var lilicount = numpic + 1;
		for(var i = 0; i <= numpic; i++){
			ulcontent += '<li></li>';
		}
		
		$('#slide').after(ulstart + ulcontent + ulend);	
	}

	pagination.on('click',DOTCHANGE)
	
	function DOTCHANGE(){
		
		var changenow = $(this).index();
		
		$('#slide li').eq(nownow).css('z-index','9');
		$('#slide li').eq(changenow).css({'z-index':'8'}).show();
		pagination.eq(changenow).addClass('current').siblings('li').removeClass('current');
		$('#slide li').eq(nownow).fadeOut(400,function(){$('#slide li').eq(changenow).fadeIn(500);});
		nownow = changenow;
	}
	
	pagination.mouseenter(function(){
		inout = 1;
	})
	
	pagination.mouseleave(function(){
		inout = 0;
	})
	
	function GOGO(){
		
		var NN = nownow+1;
		
		if( inout == 1 ){
			} else {
			if(nownow < numpic){
			$('#slide li').eq(nownow).css('z-index','9');
			$('#slide li').eq(NN).css({'z-index':'8'}).show();
			pagination.eq(NN).addClass('current').siblings('li').removeClass('current');
			$('#slide li').eq(nownow).fadeOut(400,function(){$('#slide li').eq(NN).fadeIn(500);});
			nownow += 1;

		}else{
			NN = 0;
			$('#slide li').eq(nownow).css('z-index','9');
			$('#slide li').eq(NN).stop(true,true).css({'z-index':'8'}).show();
			$('#slide li').eq(nownow).fadeOut(400,function(){$('#slide li').eq(0).fadeIn(500);});
			pagination.eq(NN).addClass('current').siblings('li').removeClass('current');

			nownow=0;

			}
		}
		TT = setTimeout(GOGO, SPEED);
	}
	
	TT = setTimeout(GOGO, SPEED); 

})

	$(function() {
		function a(a) {
			var c = parseInt(y.css("left")) + a;
			M = Math.abs(c / w),
			5 == M && (M = 1),
			a = a > 0 ? "+=" + a: "-=" + Math.abs(a),
			y.animate({
				left: a
			},
			300,
			function() {
				A && (w = $(document.body).width(), y.css("left", -w * M), A = !1),
				c > -w ? y.css("left", -$(document.body).width() * z) : -w * z > c && y.css("left", -$(document.body).width())
			})
		}
		function c() {
			C.eq(O - 1).addClass("on").siblings().removeClass("on")
		}
		function h() {
			b = setTimeout(function() {
				I.trigger("click"),
				h()
			},
			j)
		}
		function g() {
			clearTimeout(b)
		}
		function v() {
			$(".hot").animate({
				top: "-=10px"
			},
			300).animate({
				top: "+=10px"
			},
			300).animate({
				top: "-=10px"
			},
			300).animate({
				top: "+=10px"
			},
			300),
			setTimeout(v, 2e3)
		}
		var b, w = $(document.body).width(),
		k = $(".m-carousel"),
		y = $(".m-carousel .list"),
		C = $(".m-carousel .buttons span"),
		T = $(".m-carousel .prev"),
		I = $(".m-carousel .next"),
		M = 1,
		O = 1,
		z = 4,
		j = 5e3,
		A = !1;
		I.on("click",
		function() {
			y.is(":animated") || (4 == O ? O = 1 : O += 1, a( - w), c())
		}),
		T.on("click",
		function() {
			y.is(":animated") || (1 == O ? O = 4 : O -= 1, a(w), c())
		}),
		C.each(function() {
			$(this).bind("click",
			function() {
				if (!y.is(":animated") && "on" != $(this).attr("class")) {
					var h = parseInt($(this).attr("index")),
					g = -w * (h - O);
					a(g),
					O = h,
					c()
				}
			})
		}),
		k.hover(g, h),
		h(),
		$(window).on("resize",
		function() {
			A = !0,
			y.is(":animated") || (w = $(document.body).width(), y.css("left", -w * M), A = !1)
		}),
		v()
	})