/// Roughly the most-used emoji worldwide (Unicode emoji frequency data), most popular first.
/// Breaks ties so ":sad" offers 😢 before 😥.
enum Popularity {
    static let ranked: [String] = Array("""
    😂❤️🤣👍😭🙏😘🥰😍😊🎉😁💕🥺😅🔥☺️🤦♥️🤷🙄😆🤗😉🎂🤔👏🙂😳🥳😎👌💜😔💪✨💖👀😋😏😢👉💗😩💯🌹💞🎈💙😃😡💐😜🙈🤞😄🤤🙌🤪❣️😀💋💀👇💔😌💓🤩🙃😬😱😴🤭😐🌞😒😇🌸😈🎶✌️🎊🥵😞💚☀️🖤💰😚👑🎁💥🙋☹️😑🥴👈💩✅👋🤮😤🤢🌟❗😥🌈💛😝😫😲‼️🔴🌻🤯💃👊🤬🏃😕👁️⚡☕🍀💦⭐🦋🤨🌺😹🤘🌷💝💤🤝🐰😓💘🍻😟😣🧐😠🤠😻🌙😛🤙🙊🚀🫡🫠🫶👎
    """.filter { !$0.isWhitespace }).map(String.init)
}
