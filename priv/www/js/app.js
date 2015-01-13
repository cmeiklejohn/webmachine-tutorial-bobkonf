$(document).ready(function() {
  var generateTweet = function(tweet) {
    return "<li><div class='avatar' style='background: url(" +
           tweet.avatar +
           "); background-size: 50px 50px;'></div><div class='message'>" 
           + tweet.message + "</div></li>";
  };

  $('#add-tweet').click(function() {
    $('#add-tweet-form').toggle();
  });

  $('#add-tweet-submit').click(function() {
    var tweetMessageField = $('#add-tweet-message');
    var tweetMessageForm = $('#add-tweet-form');
    var tweetMessage = tweetMessageField.val();

    $.ajax({
      type: 'POST',
      url: '/tweets',
      contentType: 'application/json',
      data: JSON.stringify({ tweet: { avatar: "https://pbs.twimg.com/profile_images/528338968065355777/OfCSUPTx_400x400.jpeg", message: tweetMessage }}),
      success: function(d) {
        tweetMessageField.val('');
        tweetMessageForm.toggle();
      }
    });
  });

  $.ajax({
    url: '/tweets',
    success: function(d) {
      if(d.tweets) {
        var tweetList = $('#tweet-list');

        d.tweets.reverse().forEach(function(i) {
          tweetList.append(generateTweet(i));
        });

        if (!!window.EventSource) {
          var source = new EventSource('/tweets');

          source.addEventListener('message', function(e) {
            var tweetList = $('#tweet-list'), d = JSON.parse(e.data);
            tweetList.prepend(generateTweet(d));
          }, false);
        }
      }
    }
  });
});
