# install flask python library:
#   pip3 install flask
# test Python web app locally:
#   python3 app.py
#   http://localhost:8080
# build docker image:
#   docker build . -t pythonhelloworld
# test Python web app running in local Docker:
#   docker run -p 8080:8080 pythonhelloworld

from flask import Flask
import os
app = Flask(__name__)

@app.route("/")
def hello_world():
    return 'Hello world!'

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=os.getenv('PORT') or 8080)
